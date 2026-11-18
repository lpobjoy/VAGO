import SwiftUI
import AppKit

// MARK: - yt-dlp invocation (shared by the UI and the --cli mode)

enum Mode: String, CaseIterable, Identifiable {
    case videoMP4 = "Video — MP4 (QuickTime-compatible)"
    case audioMP3 = "Audio only — MP3"
    var id: String { rawValue }
}

/// Paths of the command-line tools bundled in Contents/Resources.
struct Tools {
    let ytdlp: String
    let ffmpeg: String
    /// JavaScript runtime yt-dlp needs for YouTube. Optional so the app still
    /// works for other sites if it is missing from the bundle.
    let deno: String?
    /// The upscale.sh pipeline and the folder holding Real-ESRGAN and its models.
    let upscaleScript: String?
    let realesrgan: String?

    static func bundled() -> Tools? {
        func path(_ name: String) -> String? { Bundle.main.path(forResource: name, ofType: nil) }
        guard let ytdlp = path("yt-dlp"), let ffmpeg = path("ffmpeg") else { return nil }
        return Tools(ytdlp: ytdlp, ffmpeg: ffmpeg, deno: path("deno"),
                     upscaleScript: path("upscale.sh"), realesrgan: path("realesrgan"))
    }

    var canUpscale: Bool { upscaleScript != nil && realesrgan != nil }

    /// A process that AI-upscales one downloaded video (see upscale.sh).
    func upscaleProcess(file: String) -> Process? {
        guard let upscaleScript, let realesrgan else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [upscaleScript, file]
        var env = ProcessInfo.processInfo.environment
        env["FFMPEG"] = ffmpeg
        env["UPSCALER"] = realesrgan + "/realesrgan-ncnn-vulkan"
        env["MODELS"] = realesrgan + "/models"
        proc.environment = env
        return proc
    }
}

/// A fresh temp file for yt-dlp to list the files it saved, one path per line.
func newFileListPath() -> String {
    NSTemporaryDirectory() + "ytgrab-files-" + UUID().uuidString + ".txt"
}

/// Reads and removes a file written via `fileList:` below.
func takeFileList(_ path: String) -> [String] {
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

func ytdlpArguments(url: String, mode: Mode, wholePlaylist: Bool,
                    destination: URL, tools: Tools, fileList: String? = nil) -> [String] {
    var args: [String] = [
        "--no-mtime",
        "--ffmpeg-location", tools.ffmpeg,
        "--newline",
        "-o", destination.path + "/%(playlist_index|)s%(playlist_index& - |)s%(title)s.%(ext)s",
    ]
    if let deno = tools.deno {
        args += ["--js-runtimes", "deno:" + deno]
    }

    if let fileList {
        // Record the final path of every saved file, for the upscaling step.
        args += ["--print-to-file", "after_move:%(filepath)s", fileList]
    }

    args += [wholePlaylist ? "--yes-playlist" : "--no-playlist"]

    switch mode {
    case .videoMP4:
        // Prefer H.264 + AAC so the result plays in QuickTime. If the site only
        // offers something else (WebM, MKV…), --recode-video converts it to MP4.
        args += ["--merge-output-format", "mp4",
                 "--recode-video", "mp4",
                 "-f", "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1]/best"]
    case .audioMP3:
        args += ["-x", "--audio-format", "mp3"]
    }

    // "--" stops option parsing, so pasted text starting with "-" is never
    // mistaken for a yt-dlp option.
    args += ["--", url]
    return args
}

// MARK: - Download engine

@MainActor
final class Downloader: ObservableObject {
    @Published var url: String = ""
    @Published var wholePlaylist: Bool = false
    @Published var mode: Mode = .videoMP4
    @Published var upscale: Bool = false
    @Published var log: String = ""
    @Published var isRunning: Bool = false
    @Published var destination: URL = {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return dl ?? FileManager.default.homeDirectoryForCurrentUser
    }()

    private var process: Process?
    private var cancelled = false

    func appendLog(_ s: String) {
        log += s
        // Keep the log from growing without bound.
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        if panel.runModal() == .OK, let u = panel.url { destination = u }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func start() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { appendLog("⚠️  Please paste a video URL first.\n"); return }
        guard let tools = Tools.bundled() else {
            appendLog("❌ Bundled tools missing from app.\n"); return
        }
        let wantsUpscale = upscale && mode == .videoMP4
        if wantsUpscale && !tools.canUpscale {
            appendLog("❌ The upscaler is missing from this build of the app.\n"); return
        }
        let fileList = wantsUpscale ? newFileListPath() : nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tools.ytdlp)
        proc.arguments = ytdlpArguments(url: trimmed, mode: mode, wholePlaylist: wholePlaylist,
                                        destination: destination, tools: tools, fileList: fileList)

        log = ""
        cancelled = false
        isRunning = true
        appendLog("▶︎ Starting…\n")
        launch(proc) { status in
            let files = fileList.map(takeFileList) ?? []
            if status == 0 && !files.isEmpty {
                self.upscaleNext(files[...], tools: tools)
            } else {
                self.finish(status)
            }
        }
    }

    /// Upscales the downloaded files one after another, then finishes.
    private func upscaleNext(_ files: ArraySlice<String>, tools: Tools) {
        guard !cancelled, let file = files.first else { finish(cancelled ? 1 : 0); return }
        guard let proc = tools.upscaleProcess(file: file) else { finish(1); return }
        appendLog("\n✨ AI upscaling…\n")
        launch(proc) { status in
            if status == 0 {
                self.upscaleNext(files.dropFirst(), tools: tools)
            } else {
                self.finish(status)
            }
        }
    }

    private func finish(_ status: Int32) {
        isRunning = false
        process = nil
        if cancelled {
            appendLog("\n⏹ Cancelled.\n")
        } else if status == 0 {
            appendLog("\n✅ Done. Saved to \(destination.path)\n")
        } else {
            appendLog("\n❌ Finished with errors (code \(status)).\n")
        }
    }

    /// Runs a process, streaming its output into the log, and calls `next`
    /// on the main actor with its exit status once it ends.
    private func launch(_ proc: Process, then next: @escaping @MainActor (Int32) -> Void) {
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Lossy decoding: a chunk may end mid-character, and dropping the
            // whole chunk (as strict decoding would) loses log lines.
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendLog(text) }
        }

        proc.terminationHandler = { p in
            let status = p.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                next(status)
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            appendLog("❌ Could not launch: \(error.localizedDescription)\n")
            next(1)
        }
    }
}

// MARK: - UI

// Brand gradient reused across the UI, matching the app icon.
let brandGradient = LinearGradient(
    colors: [
        Color(red: 0.45, green: 0.10, blue: 0.55),
        Color(red: 0.86, green: 0.13, blue: 0.27),
        Color(red: 0.98, green: 0.45, blue: 0.18),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

struct HeaderView: View {
    var body: some View {
        ZStack {
            brandGradient
            // Subtle decorative circles for a bit of depth.
            Circle().fill(.white.opacity(0.08)).frame(width: 160).offset(x: 150, y: -50)
            Circle().fill(.white.opacity(0.06)).frame(width: 90).offset(x: -160, y: 30)

            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(width: 60, height: 60)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(.white)
                        .offset(y: -6)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .offset(y: 15)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("YTGrab")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("Download video & audio from the web")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .frame(height: 110)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            )
    }
}

struct ContentView: View {
    @StateObject private var dl = Downloader()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            VStack(alignment: .leading, spacing: 16) {
                // URL + options card
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                            TextField("Paste a video URL…", text: $dl.url)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .disabled(dl.isRunning)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        )

                        HStack(spacing: 16) {
                            Picker("", selection: $dl.mode) {
                                ForEach(Mode.allCases) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 340)
                            .disabled(dl.isRunning)

                            Toggle(isOn: $dl.wholePlaylist) {
                                Label("Whole playlist", systemImage: "list.number")
                            }
                            .toggleStyle(.switch)
                            .disabled(dl.isRunning)
                        }

                        Toggle(isOn: $dl.upscale) {
                            Label("AI upscale 2× (slow — saves a second, sharper copy)",
                                  systemImage: "sparkles")
                        }
                        .toggleStyle(.switch)
                        .disabled(dl.isRunning || dl.mode != .videoMP4)

                        HStack(spacing: 10) {
                            Button {
                                dl.chooseFolder()
                            } label: {
                                Label("Save to…", systemImage: "folder")
                            }
                            .disabled(dl.isRunning)
                            Text(dl.destination.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }

                // Action button
                if dl.isRunning {
                    HStack(spacing: 12) {
                        Button(role: .destructive) { dl.cancel() } label: {
                            Label("Cancel", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button { dl.start() } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(brandGradient)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }

                // Progress log
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Progress", systemImage: "terminal")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(dl.log.isEmpty ? "Ready when you are." : dl.log)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id("log")
                            }
                            .frame(minHeight: 170)
                            .onChange(of: dl.log) { _ in
                                proxy.scrollTo("log", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 580, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Headless mode

/// `YTGrab --cli [--mp3] [--playlist] [--upscale] [-o DIR] URL` runs the same download the
/// window would, without any UI. Used by build/test.sh; handy for scripting.
func runCLI(_ arguments: [String]) -> Int32 {
    func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
    var mode = Mode.videoMP4
    var wholePlaylist = false
    var upscale = false
    var destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var url: String?

    var rest = arguments[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--mp3": mode = .audioMP3
        case "--playlist": wholePlaylist = true
        case "--upscale": upscale = true
        case "-o":
            guard let dir = rest.popFirst() else { return fail("-o needs a folder") }
            destination = URL(fileURLWithPath: dir)
        default:
            guard url == nil else { return fail("unexpected argument: \(arg)") }
            url = arg
        }
    }
    guard let url else { return fail("usage: YTGrab --cli [--mp3] [--playlist] [--upscale] [-o DIR] URL") }
    guard let tools = Tools.bundled() else { return fail("bundled tools missing from app") }

    let wantsUpscale = upscale && mode == .videoMP4
    if wantsUpscale && !tools.canUpscale { return fail("upscaler missing from app") }
    let fileList = wantsUpscale ? newFileListPath() : nil

    func run(_ proc: Process) -> Int32 {
        do {
            try proc.run()
        } catch {
            return fail("could not launch \(proc.executableURL?.lastPathComponent ?? "tool"): "
                        + error.localizedDescription)
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: tools.ytdlp)
    proc.arguments = ytdlpArguments(url: url, mode: mode, wholePlaylist: wholePlaylist,
                                    destination: destination, tools: tools, fileList: fileList)
    var status = run(proc)
    for file in fileList.map(takeFileList) ?? [] where status == 0 {
        guard let upscaler = tools.upscaleProcess(file: file) else { return 1 }
        status = run(upscaler)
    }
    return status
}

// MARK: - App entry

struct YTGrabApp: App {
    var body: some Scene {
        WindowGroup("YTGrab") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

@main
enum Main {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            exit(runCLI(Array(arguments.dropFirst())))
        }
        YTGrabApp.main()
    }
}

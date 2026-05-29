import SwiftUI
import AppKit

// MARK: - Download engine

@MainActor
final class Downloader: ObservableObject {
    @Published var url: String = ""
    @Published var wholePlaylist: Bool = false
    @Published var mode: Mode = .videoMP4
    @Published var log: String = ""
    @Published var isRunning: Bool = false
    @Published var destination: URL = {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return dl ?? FileManager.default.homeDirectoryForCurrentUser
    }()

    enum Mode: String, CaseIterable, Identifiable {
        case videoMP4 = "Video — MP4 (QuickTime-compatible)"
        case audioMP3 = "Audio only — MP3"
        var id: String { rawValue }
    }

    private var process: Process?

    // Locate the bundled binaries inside Contents/Resources
    private func resource(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: nil)
    }

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
        process?.terminate()
    }

    func start() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { appendLog("⚠️  Please paste a video URL first.\n"); return }
        guard let ytdlp = resource("yt-dlp"), let ffmpeg = resource("ffmpeg") else {
            appendLog("❌ Bundled tools missing from app.\n"); return
        }

        var args: [String] = [
            "--no-mtime",
            "--ffmpeg-location", ffmpeg,
            "--newline",
            "-o", destination.path + "/%(playlist_index|)s%(playlist_index& - |)s%(title)s.%(ext)s",
        ]

        if wholePlaylist {
            args += ["--yes-playlist"]
        } else {
            args += ["--no-playlist"]
        }

        switch mode {
        case .videoMP4:
            // Force H.264 + AAC so the result plays in QuickTime; fall back gracefully.
            args += ["--merge-output-format", "mp4",
                     "-f", "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1]/best"]
        case .audioMP3:
            args += ["-x", "--audio-format", "mp3"]
        }

        args.append(trimmed)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlp)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.appendLog(text) }
        }

        proc.terminationHandler = { p in
            Task { @MainActor in
                self.isRunning = false
                pipe.fileHandleForReading.readabilityHandler = nil
                self.appendLog(p.terminationStatus == 0
                    ? "\n✅ Done. Saved to \(self.destination.path)\n"
                    : "\n❌ Finished with errors (code \(p.terminationStatus)).\n")
            }
        }

        log = ""
        isRunning = true
        appendLog("▶︎ Starting…\n")
        do {
            try proc.run()
            self.process = proc
        } catch {
            isRunning = false
            appendLog("❌ Could not launch: \(error.localizedDescription)\n")
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
                                ForEach(Downloader.Mode.allCases) {
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

// MARK: - App entry

@main
struct YTGrabApp: App {
    var body: some Scene {
        WindowGroup("YTGrab") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

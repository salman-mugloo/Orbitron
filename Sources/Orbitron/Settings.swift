import AppKit
import SwiftUI

// MARK: - Settings window

struct SettingsView: View {
    @AppStorage("mod.convert") private var modConvert = "shift"
    @AppStorage("mod.tools") private var modTools = "command"
    @AppStorage("mod.actions") private var modActions = "control"
    @AppStorage("globalActivation") private var globalActivation = true
    @AppStorage("holdToOpen") private var holdToOpen = true
    @AppStorage("holdDelay") private var holdDelay = 0.35
    @AppStorage("jpegQuality") private var jpegQuality = 0.85
    @AppStorage("useCustomOutput") private var useCustomOutput = false
    @AppStorage("customOutputPath") private var customOutputPath = ""
    @AppStorage("terminalBundleID") private var terminal = "com.apple.Terminal"
    @AppStorage("maxJobs") private var maxJobs = 2
    @AppStorage("ffmpegPath") private var ffmpegPath = ""

    private let keys = ["shift", "command", "control", "option"]

    private func keyPicker(_ title: String, _ binding: Binding<String>) -> some View {
        Picker(title, selection: binding) {
            ForEach(keys, id: \.self) { Text($0.capitalized).tag($0) }
        }
    }

    var body: some View {
        Form {
            Section("Drag shortcuts") {
                Toggle("Enable keyboard shortcuts", isOn: $globalActivation)
                Toggle("Hold the key over a selected Finder file to open the wheel", isOn: $holdToOpen)
                HStack {
                    Text("Hold time")
                    Slider(value: $holdDelay, in: 0.15...1.0)
                    Text(String(format: "%.2fs", holdDelay)).monospacedDigit().frame(width: 52)
                }
                keyPicker("Convert wheel", $modConvert)
                keyPicker("Tools wheel", $modTools)
                keyPicker("Actions wheel", $modActions)
                Text("Select a file in Finder (or on the Desktop) and hold the key. The wheel opens under the cursor. Holding the key while dragging a file also works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Toggle("Save into a custom folder", isOn: $useCustomOutput)
                if useCustomOutput {
                    HStack {
                        Text(customOutputPath.isEmpty ? "No folder chosen" : customOutputPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseFiles = false
                            p.canChooseDirectories = true
                            p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { customOutputPath = u.path }
                        }
                    }
                } else {
                    Text("Results are saved next to the originals. Existing files are never overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("JPEG / HEIC quality")
                    Slider(value: $jpegQuality, in: 0.3...1.0)
                    Text("\(Int(jpegQuality * 100))%").monospacedDigit().frame(width: 44)
                }
            }
            Section("Performance") {
                Stepper("Concurrent jobs: \(maxJobs)", value: $maxJobs, in: 1...6)
            }
            Section("Actions") {
                Picker("Terminal app", selection: $terminal) {
                    Text("Terminal").tag("com.apple.Terminal")
                    Text("iTerm2").tag("com.googlecode.iterm2")
                    Text("Warp").tag("dev.warp.Warp-Stable")
                    Text("Ghostty").tag("com.mitchellh.ghostty")
                }
            }
            Section("Engines") {
                engineRow("Images, PDF, OCR, text, archives", "Built into macOS", true)
                engineRow("ffmpeg (audio & video)", FFmpeg.path?.path ?? "Not found — run: brew install ffmpeg", FFmpeg.path != nil)
                TextField("ffmpeg path override", text: $ffmpegPath)
                engineRow("LibreOffice (Office → PDF, XLSX ↔ CSV)",
                          Office.path?.path ?? "Not found — optional: brew install --cask libreoffice",
                          Office.path != nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private func engineRow(_ name: String, _ detail: String, _ ok: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

// MARK: - Float shelf

@MainActor
final class FloatShelf: ObservableObject {
    static let shared = FloatShelf()
    @Published var items: [URL] = []
    private var panel: NSPanel?

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        show()
    }

    func remove(_ u: URL) { items.removeAll { $0 == u } }
    func clear() { items.removeAll() }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 320),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Float Shelf"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: FloatShelfView(shelf: self))
            if let vf = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 290, y: vf.maxY - 20))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

struct FloatShelfView: View {
    @ObservedObject var shelf: FloatShelf

    var body: some View {
        VStack(spacing: 0) {
            if shelf.items.isEmpty {
                Text("Drop files with the Float action.\nThey stay here, by reference, until you drag them out.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shelf.items, id: \.self) { url in
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if !exists {
                                Text("Moved or deleted").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button { shelf.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .opacity(exists ? 1 : 0.5)
                    .onDrag { NSItemProvider(object: url as NSURL) }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear") { shelf.clear() }.disabled(shelf.items.isEmpty)
            }
            .padding(8)
        }
    }
}

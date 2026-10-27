import AppKit
import SwiftUI

// MARK: - Liquid Glass helpers (real Liquid Glass on macOS 26+, frosted material before that)

extension View {
    @ViewBuilder
    func glassCard(radius: CGFloat = 30) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.legacyGlass(radius)
        }
        #else
        self.legacyGlass(radius)
        #endif
    }

    func legacyGlass(_ radius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}

// MARK: - Model

@MainActor
final class CompressModel: ObservableObject {
    let urls: [URL]
    let singleSize: Int
    @Published var fraction = 0.5

    init(urls: [URL]) {
        self.urls = urls
        self.singleSize = urls.count == 1 ? Convert.fileSize(urls[0]) : 0
    }

    var single: Bool { urls.count == 1 }
    var targetBytes: Int { Int(Double(singleSize) * fraction) }

    var note: String {
        let ext = FileKind.ext(urls[0])
        if FileKind.imageExt.contains(ext) { return "Saved as JPEG. Quality drops first, then pixel size if needed." }
        if ext == "pdf" {
            return Convert.ghostscript != nil ? "Images are downsampled and text stays selectable."
                                              : "Pages are rebuilt as images, so text isn't selectable. Install Ghostscript to keep it."
        }
        if FileKind.videoExt.contains(ext) { return "Saved as MP4. Bitrate and resolution are chosen to fit the size." }
        return "Saved as M4A (or MP3). Bitrate is chosen to fit the size."
    }

    func start() {
        let f = fraction
        let specs = urls.map { u -> JobSpec in
            let target = max(1000, Int(Double(Convert.fileSize(u)) * f))
            return JobSpec(title: "Compress: \(u.lastPathComponent)") { try await Convert.compress(u, targetBytes: target) }
        }
        JobManager.shared.enqueue(specs)
    }
}

// MARK: - View

struct CompressView: View {
    @ObservedObject var model: CompressModel
    var close: () -> Void
    @State private var exact = ""
    @State private var unitMB = true
    @FocusState private var fieldFocused: Bool

    private func sizeString(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    private func syncExact() {
        guard model.single else { return }
        let b = Double(model.targetBytes)
        exact = unitMB ? String(format: "%.2f", b / 1_000_000) : String(Int((b / 1_000).rounded()))
    }

    private func applyExact() {
        guard model.single, model.singleSize > 0,
              let v = Double(exact.replacingOccurrences(of: ",", with: ".")) else { syncExact(); return }
        let bytes = v * (unitMB ? 1_000_000 : 1_000)
        model.fraction = min(max(bytes / Double(model.singleSize), 0.05), 0.95)
        syncExact()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.urls[0].path))
                    .resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.single ? model.urls[0].lastPathComponent : "\(model.urls.count) files")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(model.single ? "Now \(sizeString(model.singleSize))" : "Each file is compressed on its own")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                Text(model.single ? "≈ " + sizeString(model.targetBytes) : "\(Int(model.fraction * 100))% each")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                Text("−\(Int((1 - model.fraction) * 100))%")
                    .font(.title3.weight(.medium)).foregroundStyle(.secondary)
            }

            Slider(value: $model.fraction, in: 0.05...0.95).tint(.orange)

            HStack(spacing: 8) {
                ForEach([0.75, 0.5, 0.25, 0.1], id: \.self) { f in
                    Button("\(Int(f * 100))%") {
                        withAnimation(.easeInOut(duration: 0.2)) { model.fraction = f }
                    }
                    .glassButtonStyle(prominent: abs(model.fraction - f) < 0.005)
                }
                Spacer()
            }

            if model.single {
                HStack(spacing: 8) {
                    Text("Target").foregroundStyle(.secondary)
                    TextField("Size", text: $exact)
                        .textFieldStyle(.roundedBorder).frame(width: 84)
                        .focused($fieldFocused)
                        .onSubmit { applyExact() }
                    Picker("", selection: $unitMB) {
                        Text("KB").tag(false)
                        Text("MB").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 100)
                    Button("Set") { applyExact() }.glassButtonStyle(prominent: false)
                    Spacer()
                }
            }

            Text(model.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .glassButtonStyle(prominent: false)
                Button("Compress") { model.start(); close() }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(prominent: true)
            }
        }
        .padding(22)
        .frame(width: 400)
        .glassCard()
        .padding(28)
        .onAppear { syncExact() }
        .onChange(of: model.fraction) { _ in if !fieldFocused { syncExact() } }
        .onChange(of: unitMB) { _ in syncExact() }
    }
}

// MARK: - Window

@MainActor
enum CompressPanel {
    private final class Ref { weak var win: NSWindow? }
    private static var windows: [NSWindow] = []

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let model = CompressModel(urls: urls)
        let ref = Ref()
        let host = NSHostingView(rootView: CompressView(model: model, close: {
            guard let w = ref.win else { return }
            w.close()
            windows.removeAll { $0 === w }
        }))
        let win = EditorWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        ref.win = win
        win.contentView = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        windows.append(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

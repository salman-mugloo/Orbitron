import AVFoundation
import AppKit
import SwiftUI

// MARK: - Waveform

enum WaveformReader {
    static func read(_ url: URL, bins: Int = 600) throws -> (peaks: [Float], duration: Double, channels: Int) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let frames = f.length
        guard frames > 0 else { throw EngineError.empty }
        let per = AVAudioFrameCount(max(1, Int(frames) / bins))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: per) else {
            throw EngineError.unreadable(url.lastPathComponent)
        }
        var peaks: [Float] = []
        while f.framePosition < frames && peaks.count < bins {
            try f.read(into: buf, frameCount: per)
            guard buf.frameLength > 0, let data = buf.floatChannelData else { break }
            var m: Float = 0
            for c in 0..<Int(fmt.channelCount) {
                let p = data[c]
                for i in 0..<Int(buf.frameLength) { m = max(m, abs(p[i])) }
            }
            peaks.append(m)
        }
        let loudest = max(peaks.max() ?? 1, 0.0001)
        return (peaks.map { $0 / loudest }, Double(frames) / fmt.sampleRate, Int(fmt.channelCount))
    }

    /// A file AVFoundation can open; other formats (OGG, Opus, WMA…) are decoded with ffmpeg first.
    static func playable(_ url: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitron-" + UUID().uuidString + ".wav")
        try await FFmpeg.run(input: url, output: tmp, args: ["-vn", "-c:a", "pcm_s16le"])
        return tmp
    }
}

// MARK: - Model shared by the three editors

@MainActor
final class AudioModel: ObservableObject {
    let source: URL
    @Published var peaks: [Float] = []
    @Published var duration: Double = 0
    @Published var channels = 2
    @Published var loadError: String?
    @Published var busy = false

    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var trimSilence = false

    @Published var stereo = true
    @Published var left = 1.0
    @Published var right = 1.0

    @Published var bleeps: [ClosedRange<Double>] = []

    @Published var playhead: Double = 0
    @Published var isPlaying = false

    var onClose: (() -> Void)?
    private var playableURL: URL?
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var stopAt: Double?
    private var temps: [URL] = []

    init(source: URL) { self.source = source }

    func load() {
        Task {
            do {
                let p = try await WaveformReader.playable(source)
                if p != source { temps.append(p) }
                let info = try await Task.detached { try WaveformReader.read(p) }.value
                playableURL = p
                peaks = info.peaks
                duration = info.duration
                channels = info.channels
                end = info.duration
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: playback

    func play(from s: Double, to e: Double?, url: URL? = nil) {
        stop()
        guard let u = url ?? playableURL, let p = try? AVAudioPlayer(contentsOf: u) else { return }
        player = p
        p.currentTime = s
        p.prepareToPlay()
        p.play()
        isPlaying = true
        stopAt = e
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let p = player else { return }
        playhead = p.currentTime
        if !p.isPlaying || (stopAt.map { p.currentTime >= $0 } ?? false) { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        isPlaying = false
    }

    func close() {
        stop()
        for t in temps { try? FileManager.default.removeItem(at: t) }
        onClose?()
    }

    // MARK: helpers

    static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }

    var exportExt: String {
        let e = FileKind.ext(source)
        return FFmpeg.audioExts.contains(e) ? e : "m4a"
    }

    /// With "trim silent ends" on, move the handles to the first and last audible bins.
    func applySilenceTrim() {
        guard trimSilence, !peaks.isEmpty, duration > 0 else {
            if !trimSilence { start = 0; end = duration }
            return
        }
        let thr: Float = 0.03
        let first = peaks.firstIndex { $0 > thr } ?? 0
        let last = peaks.lastIndex { $0 > thr } ?? (peaks.count - 1)
        start = Double(first) / Double(peaks.count) * duration
        end = min(duration, Double(last + 1) / Double(peaks.count) * duration)
    }

    private func panFilter() -> String {
        let l = AudioModel.fmt(left), r = AudioModel.fmt(right)
        let srcL = "c0"
        let srcR = channels >= 2 ? "c1" : "c0"
        if stereo { return "pan=stereo|c0=\(l)*\(srcL)|c1=\(r)*\(srcR)" }
        return "pan=mono|c0=0.5*\(l)*\(srcL)+0.5*\(r)*\(srcR)"
    }

    private func bleepGraph() -> String {
        let cond = bleeps.map { "between(t,\(AudioModel.fmt($0.lowerBound)),\(AudioModel.fmt($0.upperBound)))" }
            .joined(separator: "+")
        let on = "gt(\(cond),0)"
        return "[0:a]volume='if(\(on),0,1)':eval=frame[a];"
            + "sine=frequency=1000:sample_rate=44100,volume='if(\(on),4,0)':eval=frame[b];"
            + "[a][b]amix=inputs=2:duration=first,volume=2[out]"
    }

    // MARK: preview + export

    private func render(_ args: [String]) {
        busy = true
        let src = source
        Task {
            defer { busy = false }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitron-prev-" + UUID().uuidString + ".wav")
            do {
                try await FFmpeg.run(input: src, output: tmp, args: args + ["-c:a", "pcm_s16le"])
                temps.append(tmp)
                play(from: 0, to: nil, url: tmp)
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func previewChannels() { render(["-vn", "-af", panFilter()]) }
    func previewBleeps() {
        guard !bleeps.isEmpty else { return }
        render(["-filter_complex", bleepGraph(), "-map", "[out]"])
    }

    private func export(_ filterArgs: [String], suffix: String) {
        let src = source
        let ext = exportExt
        let args = filterArgs + FFmpeg.audioArgs(ext)
        JobManager.shared.enqueue([
            JobSpec(title: "Edit audio: \(src.lastPathComponent)") {
                try await Convert.ffmpeg(src, to: ext, args: args, suffix: suffix)
            }
        ])
        close()
    }

    func applyTrim() { export(["-ss", AudioModel.fmt(start), "-to", AudioModel.fmt(end)], suffix: "_trimmed") }
    func applyChannels() { export(["-af", panFilter()], suffix: stereo ? "_stereo" : "_mono") }
    func applyBleeps() {
        guard !bleeps.isEmpty else { return }
        export(["-filter_complex", bleepGraph(), "-map", "[out]"], suffix: "_bleeped")
    }
}

// MARK: - Window management

final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
enum AudioEditors {
    private static var windows: [NSWindow] = []

    static func open(_ kind: EditorKind, _ url: URL) {
        let model = AudioModel(source: url)
        let host: NSHostingView<AnyView>
        switch kind {
        case .trim: host = NSHostingView(rootView: AnyView(TrimAudioView(m: model)))
        case .channels: host = NSHostingView(rootView: AnyView(ChannelsView(m: model)))
        case .bleep: host = NSHostingView(rootView: AnyView(BleepView(m: model)))
        }
        let win = EditorWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        model.onClose = { [weak win] in
            guard let win else { return }
            win.close()
            windows.removeAll { $0 === win }
        }
        windows.append(win)
        model.load()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

enum EditorKind { case trim, channels, bleep }

// MARK: - Shared SwiftUI pieces

func timeString(_ t: Double) -> String {
    let m = Int(t) / 60
    return String(format: "%d:%05.2f", m, t - Double(m * 60))
}

struct EditorCard<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            content
        }
        .padding(18)
        .frame(width: 520)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(colors: [Color.orange.opacity(0.32), Color.red.opacity(0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

struct WaveformView: View {
    enum Style { case trim, bleep }
    @ObservedObject var m: AudioModel
    let style: Style
    @State private var pending: ClosedRange<Double>?
    @State private var anchor: Double?

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        m.duration > 0 ? CGFloat(t / m.duration) * w : 0
    }
    private func t(_ px: CGFloat, _ w: CGFloat) -> Double {
        w > 0 ? min(max(0, Double(px / w)) * m.duration, m.duration) : 0
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.12))
                Canvas { ctx, size in
                    let n = m.peaks.count
                    guard n > 0 else { return }
                    let bw = size.width / CGFloat(n)
                    for (i, p) in m.peaks.enumerated() {
                        let time = Double(i) / Double(n) * m.duration
                        let bh = max(3, CGFloat(p) * size.height * 0.9)
                        let rect = CGRect(x: CGFloat(i) * bw + bw * 0.15, y: (size.height - bh) / 2,
                                          width: bw * 0.7, height: bh)
                        let color: Color
                        switch style {
                        case .trim:
                            color = (time >= m.start && time <= m.end) ? .orange : Color.orange.opacity(0.28)
                        case .bleep:
                            let hit = m.bleeps.contains { $0.contains(time) } || (pending?.contains(time) ?? false)
                            color = hit ? Color.red.opacity(0.9) : .orange
                        }
                        ctx.fill(Path(roundedRect: rect, cornerRadius: bw * 0.3), with: .color(color))
                    }
                }
                if m.isPlaying {
                    Rectangle().fill(Color.white.opacity(0.9)).frame(width: 2)
                        .position(x: x(m.playhead, w), y: h / 2)
                }
                if style == .trim && m.duration > 0 {
                    handle(h).position(x: x(m.start, w), y: h / 2)
                        .gesture(DragGesture(coordinateSpace: .named("wave")).onChanged { v in
                            m.start = min(t(v.location.x, w), m.end - 0.05)
                            m.trimSilence = false
                        })
                    handle(h).position(x: x(m.end, w), y: h / 2)
                        .gesture(DragGesture(coordinateSpace: .named("wave")).onChanged { v in
                            m.end = max(t(v.location.x, w), m.start + 0.05)
                            m.trimSilence = false
                        })
                }
            }
            .coordinateSpace(name: "wave")
            .contentShape(Rectangle())
            .gesture(style == .bleep ? DragGesture(minimumDistance: 2, coordinateSpace: .named("wave"))
                .onChanged { v in
                    let a = anchor ?? t(v.startLocation.x, w)
                    anchor = a
                    let b = t(v.location.x, w)
                    pending = min(a, b)...max(a, b)
                }
                .onEnded { _ in
                    if let p = pending, p.upperBound - p.lowerBound > 0.05 { m.bleeps.append(p) }
                    pending = nil
                    anchor = nil
                } : nil)
        }
    }

    private func handle(_ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.red)
            .frame(width: 8, height: h)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Color.white.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle().inset(by: -8))
    }
}

struct StatusLine: View {
    @ObservedObject var m: AudioModel
    var body: some View {
        if let e = m.loadError {
            Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
        } else if m.peaks.isEmpty {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading waveform…").font(.caption) }
        }
    }
}

// MARK: - Trim

struct TrimAudioView: View {
    @ObservedObject var m: AudioModel

    var body: some View {
        EditorCard(title: "Trim Audio", onClose: { m.close() }) {
            HStack {
                Text("Drag the ends to trim").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(timeString(max(0, m.end - m.start))) selected").font(.caption).monospacedDigit()
            }
            WaveformView(m: m, style: .trim).frame(height: 110)
            HStack {
                Text("Start  \(timeString(m.start))").monospacedDigit()
                Spacer()
                Text("End  \(timeString(m.end))").monospacedDigit()
            }
            .font(.caption)
            Toggle("Trim silent ends automatically", isOn: $m.trimSilence)
                .onChange(of: m.trimSilence) { _ in m.applySilenceTrim() }
            StatusLine(m: m)
            HStack {
                Button {
                    if m.isPlaying { m.stop() } else { m.play(from: m.start, to: m.end) }
                } label: {
                    Label(m.isPlaying ? "Stop" : "Play Selected Range", systemImage: m.isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(m.peaks.isEmpty)
                Spacer()
                Button("Apply") { m.applyTrim() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(m.peaks.isEmpty || m.end - m.start < 0.05)
            }
        }
    }
}

// MARK: - Channels

struct ChannelsView: View {
    @ObservedObject var m: AudioModel

    var body: some View {
        EditorCard(title: "Convert Audio Channels", onClose: { m.close() }) {
            Picker("Output", selection: $m.stereo) {
                Text("Mono").tag(false)
                Text("Stereo").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            level("Left", $m.left)
            level("Right", $m.right)
            Text(m.channels >= 2 ? "Source has \(m.channels) channels." : "Source is mono: both sides use the same signal.")
                .font(.caption).foregroundStyle(.secondary)
            StatusLine(m: m)
            HStack {
                Button {
                    if m.isPlaying { m.stop() } else { m.previewChannels() }
                } label: {
                    if m.busy { ProgressView().controlSize(.small) }
                    else { Label(m.isPlaying ? "Stop" : "Play Output", systemImage: m.isPlaying ? "stop.fill" : "play.fill") }
                }
                .disabled(m.busy)
                Spacer()
                Button("Apply") { m.applyChannels() }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
        }
    }

    private func level(_ name: String, _ v: Binding<Double>) -> some View {
        HStack {
            Text(name).frame(width: 44, alignment: .leading)
            Slider(value: v, in: 0...1.5)
            Text("\(Int(v.wrappedValue * 100))%").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Bleep

struct BleepView: View {
    @ObservedObject var m: AudioModel

    var body: some View {
        EditorCard(title: "Bleep Audio", onClose: { m.close() }) {
            HStack {
                Text("Drag across the waveform to mark a section to bleep")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Bleeps \(m.bleeps.count)").font(.caption).monospacedDigit()
            }
            WaveformView(m: m, style: .bleep).frame(height: 110)
            if !m.bleeps.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(m.bleeps.enumerated()), id: \.offset) { i, r in
                            HStack {
                                Text("\(timeString(r.lowerBound)) – \(timeString(r.upperBound))").monospacedDigit()
                                Spacer()
                                Button { m.bleeps.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
                .frame(maxHeight: 70)
            }
            StatusLine(m: m)
            HStack {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                Button("Original") { m.play(from: 0, to: nil) }.disabled(m.peaks.isEmpty)
                Button {
                    if m.isPlaying { m.stop() } else { m.previewBleeps() }
                } label: {
                    if m.busy { ProgressView().controlSize(.small) } else { Label("With Bleeps", systemImage: "play.fill") }
                }
                .disabled(m.busy || m.bleeps.isEmpty)
                Spacer()
                Button("Apply") { m.applyBleeps() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(m.bleeps.isEmpty)
            }
        }
    }
}

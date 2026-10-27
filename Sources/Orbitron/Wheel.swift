import AppKit
import ImageIO

// MARK: - The radial wheel view (also a drag destination)

final class WheelView: NSView {
    static let size: CGFloat = 400
    static let backdropRadius: CGFloat = 188
    static let hubRadius: CGFloat = 68
    private let inner: CGFloat = 68
    private let outer: CGFloat = 178
    private let pageSize = 7

    private var allOps: [Operation] = []
    private(set) var ops: [Operation] = []
    private var page = 0
    private var files: [URL] = []
    private var mode: Mode = .convert
    private var held = false
    private var thumb: NSImage?
    private var isPhoto = false
    private var sizeText = ""

    // Animation state
    private var hot: [CGFloat] = []
    private var appearT: CGFloat = 0
    private var animTimer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    private var hovered: Int? { didSet { if oldValue != hovered { kick() } } }

    var onChoose: ((Operation, [URL]) -> Void)?
    var onDismiss: (() -> Void)?
    var onCycleMode: (() -> Void)?
    var onPreviousMode: (() -> Void)?

    /// Glass arrow buttons on the inner ring: -1 = left (previous wheel), +1 = right (next wheel).
    private var navHover: Int = 0 { didSet { if oldValue != navHover { kick() } } }
    private var navPressed: Int = 0 { didSet { if oldValue != navPressed { kick() } } }
    private let navRadius: CGFloat = 16

    private func navCenter(_ side: Int) -> CGPoint {
        CGPoint(x: center.x + CGFloat(side) * inner, y: center.y)
    }

    private func navButton(at p: CGPoint) -> Int {
        guard held else { return 0 }
        for side in [-1, 1] where hypot(p.x - navCenter(side).x, p.y - navCenter(side).y) <= navRadius + 3 {
            return side
        }
        return 0
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    func configure(mode: Mode, files: [URL], ops: [Operation], held: Bool) {
        let filesChanged = self.files != files
        self.mode = mode
        self.files = files
        self.allOps = ops
        self.held = held
        self.page = 0
        rebuild()
        if filesChanged { loadPreview() }
        restartAppear()
    }

    private var pageCount: Int { max(1, Int((Double(allOps.count) / Double(pageSize)).rounded(.up))) }

    /// More than eight options → pages of seven plus a "More ›" petal.
    private func rebuild() {
        if allOps.count <= 8 {
            ops = allOps
        } else {
            let s = page * pageSize
            let slice = Array(allOps[s..<min(allOps.count, s + pageSize)])
            ops = slice + [Operation(id: "more", title: "More ›", symbol: "ellipsis",
                                     help: "Show more options", kind: .immediate({ _ in }))]
        }
        hot = Array(repeating: 0, count: ops.count)
        hovered = nil
    }

    private func restartAppear() {
        appearT = 0
        kick()
    }

    private func loadPreview() {
        thumb = nil
        isPhoto = false
        guard let first = files.first else { sizeText = ""; return }
        func bytes(_ u: URL) -> (Int64, Bool) {
            if FileKind.isDirectory(u) && FileKind.ext(u) != "rtfd" {
                var total: Int64 = 0
                var seen = 0
                if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let f as URL in en {
                        seen += 1
                        if seen > 20_000 { return (total, false) }   // huge folder: stop counting
                        total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                return (total, true)
            }
            return (Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), true)
        }
        var total: Int64 = 0
        var exact = true
        for u in files { let (b, ok) = bytes(u); total += b; exact = exact && ok }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file) + (exact ? "" : "+")
        sizeText = files.count == 1 ? size : "\(files.count) files · \(size)"
        if FileKind.imageExt.contains(FileKind.ext(first)),
           let src = CGImageSourceCreateWithURL(first as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 200,
           ] as CFDictionary) {
            thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            isPhoto = true
        } else {
            thumb = NSWorkspace.shared.icon(forFile: first.path)
        }
    }

    // MARK: Animation

    private func kick() {
        needsDisplay = true
        guard animTimer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.05, now - lastTick))
        lastTick = now
        var busy = false

        appearT += dt
        if appearT < 0.26 + 0.03 * CGFloat(ops.count) { busy = true }

        // Critically-damped style easing: smooth in and out, independent of frame rate.
        let k = 1 - exp(-dt * 14)
        for i in hot.indices {
            let target: CGFloat = (hovered == i) ? 1 : 0
            let d = target - hot[i]
            if abs(d) > 0.002 { hot[i] += d * k; busy = true } else { hot[i] = target }
        }
        needsDisplay = true
        if !busy {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    private func appear(_ i: Int) -> CGFloat {
        let raw = min(max((appearT - 0.03 * CGFloat(i)) / 0.24, 0), 1)
        let inv = 1 - raw
        return 1 - inv * inv * inv   // ease-out cubic
    }

    // MARK: Geometry

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Segment 0 starts at 12 o'clock and segments run clockwise.
    private func index(at p: CGPoint) -> Int? {
        guard !ops.isEmpty else { return nil }
        let dx = Double(p.x - center.x)
        let dy = Double(p.y - center.y)
        let r = hypot(dx, dy)
        guard r >= Double(inner), r <= Double(outer + 8) else { return nil }
        var theta = Double.pi / 2 - atan2(dy, dx)
        theta = theta.truncatingRemainder(dividingBy: 2 * Double.pi)
        if theta < 0 { theta += 2 * Double.pi }
        let step = 2 * Double.pi / Double(ops.count)
        return min(ops.count - 1, Int(theta / step))
    }

    // MARK: Drawing

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let t = image.copy() as! NSImage
        t.lockFocus()
        color.set()
        NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop)
        t.unlockFocus()
        t.isTemplate = false
        return t
    }

    private func text(_ s: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor, truncate: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = truncate ? .byTruncatingMiddle : .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        (s as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func petalColor(_ h: CGFloat) -> NSColor {
        let o = NSColor.systemOrange.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)
        return NSColor(srgbRed: 1 + (o.redComponent - 1) * h,
                       green: 1 + (o.greenComponent - 1) * h,
                       blue: 1 + (o.blueComponent - 1) * h, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = center
        let ink = NSColor(white: 0.17, alpha: 1)
        let n = ops.count

        if n > 0 {
            let stepDeg = 360.0 / Double(n)
            let gapDeg = 2.4
            for i in 0..<n {
                let a = appear(i)
                if a <= 0.001 { continue }
                let h = i < hot.count ? hot[i] : 0

                ctx.saveGState()
                // Petals bloom outward from the centre as they appear.
                let sc = 0.82 + 0.18 * a
                ctx.translateBy(x: c.x, y: c.y)
                ctx.scaleBy(x: sc, y: sc)
                ctx.translateBy(x: -c.x, y: -c.y)

                let s = 90 - Double(i) * stepDeg - gapDeg
                let e = 90 - Double(i + 1) * stepDeg + gapDeg
                let grow = 7 * h
                let path = NSBezierPath()
                path.appendArc(withCenter: c, radius: outer - 6 + grow, startAngle: CGFloat(s), endAngle: CGFloat(e), clockwise: true)
                path.appendArc(withCenter: c, radius: inner + 6, startAngle: CGFloat(e), endAngle: CGFloat(s), clockwise: false)
                path.close()
                path.lineJoinStyle = .round
                path.lineWidth = 12

                let color = petalColor(h)
                ctx.setAlpha(a * (0.55 + 0.45 * h))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                color.setFill(); color.setStroke()
                path.fill(); path.stroke()
                ctx.endTransparencyLayer()
                ctx.setAlpha(a)

                let mid = (90 - (Double(i) + 0.5) * stepDeg) * Double.pi / 180
                let r = Double(inner + outer) / 2 + Double(grow) * 0.5
                let p = CGPoint(x: c.x + CGFloat(cos(mid) * r), y: c.y + CGFloat(sin(mid) * r))
                let op = ops[i]
                let fg = NSColor(white: 0.17 + 0.83 * h, alpha: 1)
                if mode == .convert || op.id == "more" {
                    text(op.title, in: NSRect(x: p.x - 45, y: p.y - 10, width: 90, height: 22),
                         size: 16 + 1.5 * h, weight: .semibold, color: fg, truncate: true)
                } else {
                    if let img = NSImage(systemSymbolName: op.symbol, accessibilityDescription: op.title)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22 + 2 * h, weight: .medium)) {
                        let t = tinted(img, fg)
                        t.draw(in: NSRect(x: p.x - t.size.width / 2, y: p.y - t.size.height / 2 + 9,
                                          width: t.size.width, height: t.size.height))
                    }
                    text(op.title, in: NSRect(x: p.x - 45, y: p.y - 22, width: 90, height: 16),
                         size: 11, weight: .semibold, color: fg, truncate: true)
                }
                ctx.restoreGState()
            }
        }

        // Centre: a clear window onto the real file, a ring around it, and a badge with its extension.
        let hub = inner
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
        ring.lineWidth = 3
        NSColor.white.withAlphaComponent(0.95).setStroke()
        ring.stroke()
        let accent = NSBezierPath(ovalIn: NSRect(x: c.x - hub + 3, y: c.y - hub + 3, width: (hub - 3) * 2, height: (hub - 3) * 2))
        accent.lineWidth = 1.5
        NSColor.systemOrange.withAlphaComponent(0.6).setStroke()
        accent.stroke()

        let label: String
        if n == 0 {
            label = "NO OPTIONS"
        } else if let h = hovered {
            label = mode == .convert ? "\(sizeText) → \(ops[h].title.uppercased())" : "\(sizeText) · \(ops[h].title.uppercased())"
        } else {
            label = sizeText
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        let pillW = min(250, max(64, textWidth + 24))
        let pill = NSRect(x: c.x - pillW / 2, y: c.y - hub - 12, width: pillW, height: 24)
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
        let pillEdge = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        pillEdge.lineWidth = 1
        pillEdge.stroke()
        text(label, in: NSRect(x: pill.minX + 8, y: pill.minY + 4, width: pill.width - 16, height: 16),
             size: 12, weight: .bold, color: ink, truncate: true)

        if held {
            drawNavButton(side: -1, ctx: ctx)
            drawNavButton(side: 1, ctx: ctx)
        }
    }

    /// A small glass disc with a chevron, sitting on the inner ring.
    private func drawNavButton(side: Int, ctx: CGContext) {
        let hot = navHover == side
        let down = navPressed == side
        let cc = navCenter(side)
        let r = navRadius * (down ? 0.94 : (hot ? 1.1 : 1.0))
        let rect = NSRect(x: cc.x - r, y: cc.y - r, width: r * 2, height: r * 2)
        let disc = NSBezierPath(ovalIn: rect)

        // Soft drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: hot ? 9 : 6,
                      color: NSColor.black.withAlphaComponent(hot ? 0.28 : 0.2).cgColor)
        NSColor.white.withAlphaComponent(0.5).setFill()
        disc.fill()
        ctx.restoreGState()

        // Glass body: light at the top, clearer at the bottom
        ctx.saveGState()
        disc.addClip()
        let top = NSColor.white.withAlphaComponent(hot ? 0.95 : 0.8)
        let bottom = NSColor.white.withAlphaComponent(hot ? 0.55 : 0.38)
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
        if hot {
            NSColor.systemOrange.withAlphaComponent(down ? 0.35 : 0.22).setFill()
            disc.fill()
        }
        // Specular highlight along the upper edge
        let shine = NSBezierPath(ovalIn: NSRect(x: rect.minX + 3, y: rect.midY + 1, width: rect.width - 6, height: r - 3))
        NSColor.white.withAlphaComponent(0.45).setFill()
        shine.fill()
        ctx.restoreGState()

        // Rim
        NSColor.white.withAlphaComponent(0.95).setStroke()
        disc.lineWidth = 1.2
        disc.stroke()
        NSColor.systemOrange.withAlphaComponent(hot ? 0.9 : 0.55).setStroke()
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1.4, dy: 1.4))
        rim.lineWidth = 0.8
        rim.stroke()

        // Chevron
        let dir: CGFloat = side < 0 ? -1 : 1
        let chev = NSBezierPath()
        chev.move(to: CGPoint(x: cc.x - dir * 2.5, y: cc.y + 5.5))
        chev.line(to: CGPoint(x: cc.x + dir * 3, y: cc.y))
        chev.line(to: CGPoint(x: cc.x - dir * 2.5, y: cc.y - 5.5))
        chev.lineWidth = 2.2
        chev.lineCapStyle = .round
        chev.lineJoinStyle = .round
        (hot ? NSColor.systemOrange : NSColor(white: 0.17, alpha: 1)).setStroke()
        chev.stroke()
    }

    /// "PNG", "PNG · JPG", "FOLDER" … the current format of the selected file(s).
    private func extensionBadge() -> String {
        func label(_ u: URL) -> String {
            let e = u.pathExtension.uppercased()
            if FileKind.ext(u) == "<dir>" { return "FOLDER" }
            return e.isEmpty ? "FILE" : e
        }
        let unique = Array(Set(files.map(label))).sorted()
        if files.count > 1 && unique.count > 3 { return "\(files.count) FILES" }
        return unique.joined(separator: " · ")
    }

    // MARK: Click mode

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        navHover = navButton(at: p)
        hovered = navHover != 0 ? nil : index(at: p)
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; navHover = 0; navPressed = 0 }

    /// Returns true when a real option was chosen ("More ›" only flips the page).
    @discardableResult
    private func activate(_ i: Int) -> Bool {
        let op = ops[i]
        if op.id == "more" {
            page = (page + 1) % pageCount
            rebuild()
            restartAppear()
            return false
        }
        onChoose?(op, files)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard held else { return }
        let p = convert(event.locationInWindow, from: nil)
        let nav = navButton(at: p)
        if nav != 0 {
            navPressed = nav
            if nav < 0 { onPreviousMode?() } else { onCycleMode?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.navPressed = 0 }
        } else if let i = index(at: p) {
            activate(i)
        } else if hypot(p.x - center.x, p.y - center.y) < inner {
            onCycleMode?()
        } else {
            onDismiss?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onDismiss?()      // Esc
        case 48: onCycleMode?()    // Tab
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drag destination (live Finder drags)

    private func dragOp(_ s: NSDraggingInfo) -> NSDragOperation {
        let m = s.draggingSourceOperationMask
        for op in [NSDragOperation.copy, .generic, .link, .move] where m.contains(op) { return op }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        return hovered == nil ? [] : dragOp(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        if ops[i].id == "more" { activate(i); return false }
        let fromPB = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let urls = (fromPB?.isEmpty == false) ? fromPB! : files
        let op = ops[i]
        Task { @MainActor [weak self] in self?.onChoose?(op, urls) }
        return true
    }
}

// MARK: - Panel

final class WheelPanel: NSPanel {
    var allowKey = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
final class WheelController {
    static let shared = WheelController()

    private let view: WheelView
    private let panel: WheelPanel
    private(set) var isVisible = false
    private(set) var held = false
    private(set) var mode: Mode = .convert
    private var files: [URL] = []
    private var hideToken = 0

    private init() {
        let s = WheelView.size
        let r = WheelView.backdropRadius
        let v = WheelView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        let container = NSView(frame: v.frame)

        // Frosted circular backdrop behind the petals.
        let fx = NSVisualEffectView(frame: NSRect(x: s / 2 - r, y: s / 2 - r, width: r * 2, height: r * 2))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .aqua)
        fx.wantsLayer = true
        // Ring-shaped mask: the middle stays see-through so the selected file remains visible.
        let hole = WheelView.hubRadius
        let maskPath = CGMutablePath()
        maskPath.addEllipse(in: CGRect(x: 0, y: 0, width: r * 2, height: r * 2))
        maskPath.addEllipse(in: CGRect(x: r - hole, y: r - hole, width: hole * 2, height: hole * 2))
        let mask = CAShapeLayer()
        mask.frame = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        mask.path = maskPath
        mask.fillRule = .evenOdd
        fx.layer?.mask = mask
        container.addSubview(fx)
        container.addSubview(v)

        view = v
        panel = WheelPanel(contentRect: container.frame)
        panel.contentView = container
        v.onChoose = { [weak self] op, urls in self?.choose(op, urls) }
        v.onDismiss = { [weak self] in self?.hide() }
        v.onCycleMode = { [weak self] in
            guard let self else { return }
            self.setMode(self.mode.next)
        }
        v.onPreviousMode = { [weak self] in
            guard let self else { return }
            self.setMode(self.mode.previous)
        }
    }

    func show(files: [URL], mode: Mode, held: Bool, at point: NSPoint) {
        self.files = files
        self.held = held
        panel.allowKey = held
        hideToken += 1

        let s = WheelView.size
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        var origin = CGPoint(x: point.x - s / 2, y: point.y - s / 2)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - s)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - s)
        }
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: s, height: s)), display: false)
        setMode(mode)

        let wasVisible = isVisible
        isVisible = true
        if !wasVisible { panel.alphaValue = 0 }
        if held {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func setMode(_ m: Mode) {
        mode = m
        view.configure(mode: m, files: files, ops: Registry.operations(for: m, files: files), held: held)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        held = false
        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.hideToken == token, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func choose(_ op: Operation, _ urls: [URL]) {
        hide()
        switch op.kind {
        case .jobs(let plan):
            JobManager.shared.enqueue(plan(urls))
        case .immediate(let run):
            run(urls)
        }
    }
}

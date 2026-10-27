import AppKit
import SwiftUI

@main
struct OrbitronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Everything lives in the menu bar; windows are created by AppDelegate.
        Settings { EmptyView() }
    }
}

// MARK: - Window hub

@MainActor
enum Windows {
    private static var jobs: NSWindow?
    private static var drop: NSWindow?
    private static var settings: NSWindow?

    static func showJobs() {
        if jobs == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: JobsView(manager: JobManager.shared)))
            w.title = "Orbitron — Jobs"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 480, height: 300))
            w.center()
            jobs = w
        }
        jobs?.orderFrontRegardless()
    }

    static func hideJobs() { jobs?.orderOut(nil) }

    static func showDropZone() {
        if drop == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 528, height: 200),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Orbitron — Drop Zone"
            w.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 528, height: 200))
            for (i, m) in Mode.allCases.enumerated() {
                let tile = DropTile(mode: m, frame: NSRect(x: 12 + CGFloat(i) * 168, y: 12, width: 168, height: 176))
                content.addSubview(tile)
            }
            w.contentView = content
            w.center()
            drop = w
        }
        NSApp.activate(ignoringOtherApps: true)
        drop?.makeKeyAndOrderFront(nil)
    }

    static func showSettings() {
        if settings == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Orbitron Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Drop zone (fallback when system-wide drag detection is unavailable)

final class DropTile: NSView {
    private let tileMode: Mode
    private var highlighted = false { didSet { needsDisplay = true } }

    init(mode: Mode, frame: NSRect) {
        tileMode = mode
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 16, yRadius: 16)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
        path.fill()
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        let sub: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]
        let modKey = Prefs.modifier(for: tileMode)
        let keyName = modKey.contains(.command) ? "⌘" : modKey.contains(.control) ? "⌃" : modKey.contains(.option) ? "⌥" : "⇧"
        (tileMode.title as NSString).draw(in: NSRect(x: 8, y: bounds.midY, width: bounds.width - 16, height: 24), withAttributes: title)
        ("Drop files here, or click to browse\nDrag shortcut: \(keyName)" as NSString)
            .draw(in: NSRect(x: 12, y: bounds.midY - 44, width: bounds.width - 24, height: 40), withAttributes: sub)
    }

    private func present(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let m = tileMode
        Task { @MainActor in
            WheelController.shared.show(files: urls, mode: m, held: true, at: NSEvent.mouseLocation)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlighted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        present(urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Choose"
        if p.runModal() == .OK { present(p.urls) }
    }
}

// MARK: - App delegate and menu bar item

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private let coordinator = DragCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle",
                                     accessibilityDescription: "Orbitron")
        let menu = NSMenu()
        menu.addItem(menuItem("Open Drop Zone", #selector(openDropZone), ""))
        menu.addItem(menuItem("Show Jobs", #selector(openJobs), ""))
        menu.addItem(menuItem("Float Shelf", #selector(openShelf), ""))
        menu.addItem(.separator())
        let pause = menuItem("Pause Drag Shortcuts", #selector(togglePause), "")
        pause.state = Prefs.globalActivation ? .off : .on
        pauseItem = pause
        menu.addItem(pause)
        menu.addItem(menuItem("Settings…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Orbitron", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        coordinator.start()
        Windows.showDropZone()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openDropZone() { Windows.showDropZone() }
    @objc private func openJobs() { Windows.showJobs() }
    @objc private func openShelf() { FloatShelf.shared.show() }
    @objc private func openSettings() { Windows.showSettings() }

    @objc private func togglePause() {
        Prefs.globalActivation.toggle()
        pauseItem?.state = Prefs.globalActivation ? .off : .on
    }
}

import AppKit

/// Watches for a file drag that is in progress anywhere on screen and shows the wheel
/// when the user holds one of the configured modifier keys.
///
/// Mouse monitors need no special permission. The modifier state is read with
/// `NSEvent.modifierFlags` (a class property) instead of a key monitor, so Input
/// Monitoring access isn't required either.
@MainActor
final class DragCoordinator {
    private var monitors: [Any] = []
    private var timer: Timer?
    private var downChange = 0
    private var cachedChange = -1
    private var cachedFiles: [URL] = []
    private var releasedAt: Date?
    private var holdTimer: Timer?
    private var holdSince: Date?
    private var holdMode: Mode?
    private var holdFired = false

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.mouseDragged() }
        }
        monitors = [down, drag].compactMap { $0 }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.holdTick() }
        }
    }

    /// Select-and-hold: with a file selected in Finder, holding a wheel key (alone, no mouse
    /// button, for `holdDelay` seconds) opens the wheel under the cursor.
    private func holdTick() {
        guard Prefs.globalActivation, Prefs.holdToOpen else { return }
        let wheel = WheelController.shared
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        guard let m = Mode.allCases.first(where: { flags == Prefs.modifier(for: $0) }) else {
            holdSince = nil; holdMode = nil; holdFired = false
            return
        }
        if holdMode != m {
            holdMode = m
            holdSince = Date()
            holdFired = false
            // Wheel already open and waiting: switch it to the newly pressed mode.
            if wheel.isVisible && wheel.held { wheel.setMode(m); holdFired = true }
            return
        }
        guard !holdFired, let since = holdSince, Date().timeIntervalSince(since) >= Prefs.holdDelay else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        holdFired = true
        let files = FinderSelection.current()
        guard !files.isEmpty else { return }
        wheel.show(files: files, mode: m, held: true, at: NSEvent.mouseLocation)
    }

    private func mouseDown() {
        downChange = NSPasteboard(name: .drag).changeCount
        // A click on any other app dismisses a wheel that is waiting for a click.
        let wheel = WheelController.shared
        if wheel.isVisible && wheel.held { wheel.hide() }
    }

    private func mouseDragged() {
        guard Prefs.globalActivation, timer == nil else { return }
        releasedAt = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        releasedAt = nil
    }

    private func tick() {
        let wheel = WheelController.shared
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0

        if !buttonDown {
            // Drag finished. Give a drop on the wheel a moment to be delivered, then tidy up.
            if wheel.isVisible && !wheel.held {
                if let t = releasedAt {
                    if Date().timeIntervalSince(t) > 0.4 { wheel.hide(); stopTimer() }
                } else {
                    releasedAt = Date()
                }
            } else {
                stopTimer()
            }
            return
        }
        releasedAt = nil
        guard Prefs.globalActivation else { return }

        let pb = NSPasteboard(name: .drag)
        // Only a pasteboard that changed after this mouse-down belongs to the current drag.
        guard pb.changeCount != downChange else { return }
        if pb.changeCount != cachedChange {
            cachedChange = pb.changeCount
            cachedFiles = (pb.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        guard !cachedFiles.isEmpty else { return }

        let flags = NSEvent.modifierFlags
        guard let m = Mode.allCases.first(where: { flags.contains(Prefs.modifier(for: $0)) }) else { return }
        if !wheel.isVisible {
            wheel.show(files: cachedFiles, mode: m, held: false, at: NSEvent.mouseLocation)
        } else if !wheel.held && wheel.mode != m {
            wheel.setMode(m)
        }
    }
}

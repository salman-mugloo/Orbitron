import AppKit

/// Reads the current Finder selection (including the Desktop) through Apple Events.
/// The first call makes macOS ask for permission to control Finder.
@MainActor
enum FinderSelection {
    private static var warned = false

    static func current() -> [URL] {
        let src = """
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: src) else { return [] }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            let code = err["NSAppleScriptErrorNumber"] as? Int ?? 0
            if code == -1743, !warned {
                warned = true
                Dialogs.text("Orbitron needs permission",
                             "Allow Orbitron to control Finder in System Settings → Privacy & Security → Automation, then hold the key again.")
            }
            return []
        }
        let text = result.stringValue ?? ""
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

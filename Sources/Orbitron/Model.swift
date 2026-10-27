import AppKit
import Foundation

// MARK: - Wheel modes

enum Mode: String, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    var defaultModifier: String {
        switch self {
        case .convert: return "shift"
        case .tools: return "command"
        case .actions: return "control"
        }
    }

    var next: Mode {
        switch self {
        case .convert: return .tools
        case .tools: return .actions
        case .actions: return .convert
        }
    }

    var previous: Mode {
        switch self {
        case .convert: return .actions
        case .tools: return .convert
        case .actions: return .tools
        }
    }

    var prefKey: String { "mod." + rawValue }
}

// MARK: - Jobs and operations

struct JobSpec {
    let title: String
    let work: @Sendable () async throws -> [URL]
}

enum OpKind {
    /// Background work: produces one JobSpec per unit of work.
    case jobs(([URL]) -> [JobSpec])
    /// Runs immediately on the main thread (dialogs, clipboard, sharing…).
    case immediate(@MainActor ([URL]) -> Void)
}

struct Operation: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let help: String
    let kind: OpKind
}

// MARK: - Errors

enum EngineError: LocalizedError {
    case unreadable(String)
    case missingTool(String)
    case failed(String)
    case passwordProtected
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let n): return "Couldn't read “\(n)”. It may be corrupt or an unsupported variant."
        case .missingTool(let t): return "Required engine not found: \(t)."
        case .failed(let m): return m
        case .passwordProtected: return "This file is password-protected."
        case .empty: return "The file has no content to convert."
        }
    }
}

// MARK: - File kinds

enum FileKind {
    static let imageExt: Set<String> = ["jpg", "png", "heic", "tiff", "bmp", "gif", "webp", "avif"]
    static let audioExt: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma", "aac"]
    static let videoExt: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v"]
    static let textutilIn: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "txt", "webarchive"]
    static let sheetExt: Set<String> = ["xlsx", "xls", "ods"]
    static let slidesExt: Set<String> = ["pptx", "ppt", "odp"]

    /// Normalised lowercase extension. Directories (other than .rtfd) return "<dir>".
    static func ext(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "tgz" }
        var e = url.pathExtension.lowercased()
        switch e {
        case "jpeg": e = "jpg"
        case "tif": e = "tiff"
        case "heif": e = "heic"
        case "htm": e = "html"
        case "aif": e = "aiff"
        case "markdown": e = "md"
        default: break
        }
        if e != "rtfd" && isDirectory(url) { return "<dir>" }
        return e
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func all(_ files: [URL], in set: Set<String>) -> Bool {
        !files.isEmpty && files.allSatisfy { set.contains(ext($0)) }
    }
}

// MARK: - Preferences (keys match @AppStorage in SettingsView)

enum Prefs {
    private static var d: UserDefaults { .standard }

    static var jpegQuality: Double { d.object(forKey: "jpegQuality") as? Double ?? 0.85 }
    static var useCustomOutput: Bool { d.bool(forKey: "useCustomOutput") }
    static var customOutputPath: String { d.string(forKey: "customOutputPath") ?? "" }
    static var terminalBundleID: String { d.string(forKey: "terminalBundleID") ?? "com.apple.Terminal" }
    static var maxJobs: Int { max(1, d.object(forKey: "maxJobs") as? Int ?? 2) }
    static var ffmpegPath: String { d.string(forKey: "ffmpegPath") ?? "" }

    static var holdToOpen: Bool { d.object(forKey: "holdToOpen") as? Bool ?? true }
    static var holdDelay: Double { d.object(forKey: "holdDelay") as? Double ?? 0.35 }

    static var globalActivation: Bool {
        get { d.object(forKey: "globalActivation") as? Bool ?? true }
        set { d.set(newValue, forKey: "globalActivation") }
    }

    static func modifier(for mode: Mode) -> NSEvent.ModifierFlags {
        switch d.string(forKey: mode.prefKey) ?? mode.defaultModifier {
        case "command": return .command
        case "control": return .control
        case "option": return .option
        default: return .shift
        }
    }
}

// MARK: - Simple text dialog

@MainActor
enum Dialogs {
    static func text(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = body
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.runModal()
    }
}

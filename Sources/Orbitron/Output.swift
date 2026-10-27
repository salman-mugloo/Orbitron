import AppKit
import Foundation

/// Decides where output goes, names it without overwriting anything, and only
/// publishes a result after it has been written completely and validated.
enum OutputManager {
    static var sessionFolder: URL?

    static func directory(for source: URL) async throws -> URL {
        if Prefs.useCustomOutput, !Prefs.customOutputPath.isEmpty {
            let u = URL(fileURLWithPath: Prefs.customOutputPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let dir = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        if let s = sessionFolder { return s }

        let picked: URL? = await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.canChooseFiles = false
            p.canChooseDirectories = true
            p.canCreateDirectories = true
            p.prompt = "Save Here"
            p.message = "The original folder isn't writable. Choose where to save the result."
            return p.runModal() == .OK ? p.url : nil
        }
        guard let picked else { throw EngineError.failed("No output folder was chosen.") }
        sessionFolder = picked
        return picked
    }

    static func uniqueName(_ name: String, _ i: Int) -> String {
        if i == 0 { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base)_\(i)" : "\(base)_\(i).\(ext)"
    }

    /// A URL in `dir` that doesn't exist yet (photo.jpg, photo_1.jpg, …).
    static func freeURL(name: String, in dir: URL) -> URL {
        for i in 0..<10_000 {
            let u = dir.appendingPathComponent(uniqueName(name, i))
            if !FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return dir.appendingPathComponent(UUID().uuidString + "_" + name)
    }

    static func validate(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw EngineError.failed("The engine finished but produced no output.")
        }
        if isDir.boolValue {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count ?? 0
            guard n > 0 else { throw EngineError.failed("The output folder is empty.") }
        } else {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw EngineError.failed("The output file is empty.") }
        }
    }

    static func finalize(_ tmp: URL, in dir: URL, name: String) throws -> URL {
        for i in 0..<10_000 {
            let dest = dir.appendingPathComponent(uniqueName(name, i))
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                return dest
            } catch let e as CocoaError where e.code == .fileWriteFileExists {
                continue
            }
        }
        throw EngineError.failed("Couldn't find a free file name for “\(name)”.")
    }

    /// Runs `work` against a hidden temp file, validates it, then moves it into place.
    static func produce(source: URL, fileName: String, work: (URL) async throws -> Void) async throws -> URL {
        let dir = try await directory(for: source)
        let ext = (fileName as NSString).pathExtension
        let tmpName = ".orbitron-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let tmp = dir.appendingPathComponent(tmpName)
        do {
            try await work(tmp)
            try Task.checkCancellation()
            try validate(tmp)
            return try finalize(tmp, in: dir, name: fileName)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Same, for operations that produce a folder of files.
    static func produceFolder(source: URL, name: String, work: (URL) async throws -> Void) async throws -> URL {
        let dir = try await directory(for: source)
        let tmp = dir.appendingPathComponent(".orbitron-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try await work(tmp)
            try Task.checkCancellation()
            try validate(tmp)
            return try finalize(tmp, in: dir, name: name)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Process runner (argument arrays only, never a shell)

final class LockedData {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data.suffix(1500), as: UTF8.self)
    }
}

enum ProcessRunner {
    static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, stdoutTo: URL? = nil) async throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice

        var outHandle: FileHandle?
        if let o = stdoutTo {
            FileManager.default.createFile(atPath: o.path, contents: nil)
            outHandle = try FileHandle(forWritingTo: o)
            p.standardOutput = outHandle
        } else {
            p.standardOutput = FileHandle.nullDevice
        }
        defer { try? outHandle?.close() }

        let errPipe = Pipe()
        p.standardError = errPipe
        let err = LockedData()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { err.append(d) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                p.terminationHandler = { proc in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: EngineError.failed(
                            "\(exe.lastPathComponent) failed (code \(proc.terminationStatus)). \(err.tail)"))
                    }
                }
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: EngineError.failed(
                        "Couldn't launch \(exe.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

// MARK: - Image engine (ImageIO)

enum ImageEngine {
    static let typeIDs: [String: String] = [
        "jpg": UTType.jpeg.identifier,
        "png": UTType.png.identifier,
        "heic": UTType.heic.identifier,
        "tiff": UTType.tiff.identifier,
        "bmp": UTType.bmp.identifier,
        "gif": UTType.gif.identifier,
    ]

    static func canWrite(_ ext: String) -> Bool {
        guard let id = typeIDs[ext] else { return false }
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains(id)
    }

    /// Loads with EXIF orientation applied. `scale` is clamped to 1 – never upscales.
    static func load(_ url: URL, scale: Double = 1) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw EngineError.unreadable(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { throw EngineError.unreadable(url.lastPathComponent) }
        let target = max(1, Int((Double(max(w, h)) * min(scale, 1)).rounded()))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw EngineError.unreadable(url.lastPathComponent)
        }
        return img
    }

    /// Writes without copying source metadata (so re-encoding also strips EXIF/GPS).
    static func write(_ image: CGImage, ext: String, quality: Double, to url: URL) throws {
        guard let id = typeIDs[ext], canWrite(ext) else {
            throw EngineError.failed("This Mac can't write .\(ext) files.")
        }
        let img = (ext == "jpg") ? flatten(image) : image
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, id as CFString, 1, nil) else {
            throw EngineError.failed("Couldn't create the output file.")
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.failed("Encoding .\(ext) failed.") }
    }

    /// JPEG has no alpha: composite onto white.
    private static func flatten(_ img: CGImage) -> CGImage {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return img
        default: break
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    static func metadata(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            return "No metadata found."
        }
        var lines: [String] = []
        func walk(_ d: [String: Any], _ prefix: String) {
            for k in d.keys.sorted() {
                if let sub = d[k] as? [String: Any] {
                    walk(sub, prefix + k + " ▸ ")
                } else if let v = d[k] {
                    lines.append("\(prefix)\(k): \(v)")
                }
            }
        }
        walk(p, "")
        return lines.isEmpty ? "No metadata found." : lines.joined(separator: "\n")
    }

    static func qr(_ url: URL) throws -> [String] {
        let img = try load(url)
        let req = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let results = (req.results as? [VNBarcodeObservation]) ?? []
        return results.compactMap { $0.payloadStringValue }
    }
}

// MARK: - PDF engine (PDFKit + Vision)

enum PDFEngine {
    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        let b = page.bounds(for: .mediaBox)
        let size = CGSize(width: max(1, b.width * scale), height: max(1, b.height * scale))
        let ns = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw EngineError.failed("Couldn't render a PDF page.")
        }
        return cg
    }

    static func ocr(_ image: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw EngineError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw EngineError.passwordProtected }
        guard doc.pageCount > 0 else { throw EngineError.empty }
        return doc
    }
}

// MARK: - External engines

enum FFmpeg {
    static var path: URL? {
        var c: [String] = []
        if !Prefs.ffmpegPath.isEmpty { c.append(Prefs.ffmpegPath) }
        c += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func run(input: URL, output: URL, args: [String]) async throws {
        guard let exe = path else { throw EngineError.missingTool("ffmpeg (install with: brew install ffmpeg)") }
        let full = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path] + args + [output.path]
        try await ProcessRunner.run(exe, full)
    }

    static let encoderList: String = {
        guard let exe = path else { return "" }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()

    static func hasEncoder(_ name: String) -> Bool { encoderList.contains(" \(name) ") }

    static let audioExts: Set<String> = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aac"]

    static func audioArgs(_ ext: String) -> [String] {
        switch ext {
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "aac": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        default: return ["-vn"]
        }
    }

    static func videoArgs(_ ext: String) -> [String] {
        let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        switch ext {
        case "mp4": return ["-vf", even, "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "mov": return ["-vf", even, "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
        case "mkv": return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-c:a", "aac"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame", "-q:a", "3"]
        case "gif": return ["-an", "-vf", "fps=12,scale='min(480,iw)':-1:flags=lanczos", "-loop", "0"]
        default: return []
        }
    }
}

enum Office {
    static var path: URL? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - Text, CSV and subtitle helpers

enum TextTools {
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        throw EngineError.unreadable(url.lastPathComponent)
    }

    static func parseCSV(_ s: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func writeCSV(_ rows: [[String]], delimiter: Character) -> String {
        let d = String(delimiter)
        return rows.map { r in
            r.map { f -> String in
                if f.contains(d) || f.contains("\"") || f.contains("\n") || f.contains("\r") {
                    return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return f
            }.joined(separator: d)
        }.joined(separator: "\n") + "\n"
    }

    static func lines(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func srtToVTT(_ s: String) -> String {
        var out = ["WEBVTT", ""]
        for l in lines(s) {
            out.append(l.contains("-->") ? l.replacingOccurrences(of: ",", with: ".") : l)
        }
        return out.joined(separator: "\n")
    }

    private static func srtTime(_ t: String) -> String {
        var parts = t.split(separator: ":").map(String.init)
        if parts.count == 2 { parts.insert("00", at: 0) }
        return parts.joined(separator: ":").replacingOccurrences(of: ".", with: ",")
    }

    static func vttToSRT(_ s: String) -> String {
        let blocks = lines(s).split(separator: "", omittingEmptySubsequences: true).map { Array($0) }
        var out: [String] = []
        var n = 1
        for b in blocks {
            guard let first = b.first else { continue }
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") { continue }
            guard let ti = b.firstIndex(where: { $0.contains("-->") }) else { continue }
            let tokens = b[ti].split(separator: " ").map(String.init)
            guard tokens.count >= 3 else { continue }
            let timing = srtTime(tokens[0]) + " --> " + srtTime(tokens[2])
            let text = b[(ti + 1)...].joined(separator: "\n")
            out.append("\(n)\n\(timing)\n\(text)\n")
            n += 1
        }
        return out.joined(separator: "\n")
    }

    static func subtitleToText(_ s: String) -> String {
        var out: [String] = []
        for l in lines(s) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.contains("-->") || t.hasPrefix("WEBVTT") || Int(t) != nil { continue }
            out.append(t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Archive safety

enum ArchiveSafety {
    /// Rejects extraction results that escape the destination (zip-slip, symlinks pointing out).
    static func verify(_ root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let u as URL in en {
            let p = u.resolvingSymlinksInPath().path
            if p != rootPath && !p.hasPrefix(rootPath + "/") {
                throw EngineError.failed("The archive tried to write outside its destination and was rejected.")
            }
        }
    }
}

// MARK: - Conversion jobs

enum Convert {
    static func base(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }

    // Images
    static func image(_ url: URL, to ext: String, scale: Double = 1, suffix: String = "", quality: Double? = nil) async throws -> [URL] {
        let q = quality ?? Prefs.jpegQuality
        let out = try await OutputManager.produce(source: url, fileName: base(url) + suffix + "." + ext) { tmp in
            let img = try ImageEngine.load(url, scale: scale)
            try ImageEngine.write(img, ext: ext, quality: q, to: tmp)
        }
        return [out]
    }

    static func imagesToPDF(_ urls: [URL], suffix: String = "") async throws -> [URL] {
        guard let first = urls.first else { return [] }
        let out = try await OutputManager.produce(source: first, fileName: base(first) + suffix + ".pdf") { tmp in
            let doc = PDFDocument()
            for (i, u) in urls.enumerated() {
                try Task.checkCancellation()
                guard let img = NSImage(contentsOf: u), let page = PDFPage(image: img) else {
                    throw EngineError.unreadable(u.lastPathComponent)
                }
                doc.insert(page, at: i)
            }
            guard doc.write(to: tmp) else { throw EngineError.failed("Couldn't write the PDF.") }
        }
        return [out]
    }

    // PDF
    static func pdfToImages(_ url: URL, ext: String) async throws -> [URL] {
        let doc = try PDFEngine.open(url)
        let n = doc.pageCount
        let q = Prefs.jpegQuality
        if n == 1 {
            let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
                guard let page = doc.page(at: 0) else { throw EngineError.empty }
                try ImageEngine.write(try PDFEngine.render(page), ext: ext, quality: q, to: tmp)
            }
            return [out]
        }
        let dir = try await OutputManager.produceFolder(source: url, name: base(url) + "_pages") { tmp in
            for i in 0..<n {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                let target = tmp.appendingPathComponent("\(base(url))-\(i + 1).\(ext)")
                try ImageEngine.write(try PDFEngine.render(page), ext: ext, quality: q, to: target)
            }
        }
        return [dir]
    }

    static func pdfText(_ url: URL) async throws -> [URL] {
        let doc = try PDFEngine.open(url)
        let out = try await OutputManager.produce(source: url, fileName: base(url) + ".txt") { tmp in
            var text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Scanned PDF: fall back to on-device OCR.
                var parts: [String] = []
                for i in 0..<doc.pageCount {
                    try Task.checkCancellation()
                    if let p = doc.page(at: i) { parts.append(try PDFEngine.ocr(try PDFEngine.render(p, scale: 3))) }
                }
                text = parts.joined(separator: "\n\n")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineError.failed("No text could be found in this PDF.")
            }
            try text.write(to: tmp, atomically: false, encoding: .utf8)
        }
        return [out]
    }

    static func mergePDFs(_ urls: [URL]) async throws -> [URL] {
        guard let first = urls.first else { return [] }
        let out = try await OutputManager.produce(source: first, fileName: base(first) + "_merged.pdf") { tmp in
            let merged = PDFDocument()
            for u in urls {
                let d = try PDFEngine.open(u)
                for i in 0..<d.pageCount {
                    if let p = d.page(at: i)?.copy() as? PDFPage { merged.insert(p, at: merged.pageCount) }
                }
            }
            guard merged.write(to: tmp) else { throw EngineError.failed("Couldn't write the merged PDF.") }
        }
        return [out]
    }

    static func splitPDF(_ url: URL) async throws -> [URL] {
        let doc = try PDFEngine.open(url)
        let dir = try await OutputManager.produceFolder(source: url, name: base(url) + "_split") { tmp in
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                let single = PDFDocument()
                if let p = doc.page(at: i)?.copy() as? PDFPage { single.insert(p, at: 0) }
                let target = tmp.appendingPathComponent("\(base(url))_page\(i + 1).pdf")
                guard single.write(to: target) else { throw EngineError.failed("Couldn't write page \(i + 1).") }
            }
        }
        return [dir]
    }

    // Audio / video via ffmpeg
    static func ffmpeg(_ url: URL, to ext: String, args: [String], suffix: String = "") async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + suffix + "." + ext) { tmp in
            try await FFmpeg.run(input: url, output: tmp, args: args)
        }
        return [out]
    }

    static func media(_ url: URL, to ext: String) async throws -> [URL] {
        let args = FFmpeg.audioExts.contains(ext) ? FFmpeg.audioArgs(ext) : FFmpeg.videoArgs(ext)
        return try await ffmpeg(url, to: ext, args: args)
    }

    // Documents
    static func textutil(_ url: URL, to ext: String) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/textutil"),
                                        ["-convert", ext, "-output", tmp.path, url.path])
        }
        return [out]
    }

    static func office(_ url: URL, to ext: String) async throws -> [URL] {
        guard let exe = Office.path else { throw EngineError.missingTool("LibreOffice (brew install --cask libreoffice)") }
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("orbitron-lo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try await ProcessRunner.run(exe, ["--headless", "--convert-to", ext, "--outdir", work.path, url.path])
            guard let produced = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first else {
                throw EngineError.failed("LibreOffice produced no output.")
            }
            try FileManager.default.moveItem(at: produced, to: tmp)
        }
        return [out]
    }

    // Text formats
    static func textTransform(_ url: URL, to ext: String, _ f: @escaping @Sendable (String) -> String) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
            let s = try TextTools.read(url)
            try f(s).write(to: tmp, atomically: false, encoding: .utf8)
        }
        return [out]
    }

    static func delimited(_ url: URL, from: Character, to: Character, ext: String) async throws -> [URL] {
        try await textTransform(url, to: ext) { s in
            TextTools.writeCSV(TextTools.parseCSV(s, delimiter: from), delimiter: to)
        }
    }

    // Archives
    private static let zipURL = URL(fileURLWithPath: "/usr/bin/zip")
    private static let tarURL = URL(fileURLWithPath: "/usr/bin/tar")
    private static let gzipURL = URL(fileURLWithPath: "/usr/bin/gzip")
    private static let unzipURL = URL(fileURLWithPath: "/usr/bin/unzip")

    static func zip(_ url: URL) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: url.lastPathComponent + ".zip") { tmp in
            try await ProcessRunner.run(zipURL, ["-r", "-q", "-X", tmp.path, url.lastPathComponent],
                                        cwd: url.deletingLastPathComponent())
        }
        return [out]
    }

    static func zipTogether(_ urls: [URL]) async throws -> [URL] {
        guard let first = urls.first else { return [] }
        let out = try await OutputManager.produce(source: first, fileName: "Archive.zip") { tmp in
            try await ProcessRunner.run(zipURL, ["-r", "-q", "-X", tmp.path] + urls.map { $0.lastPathComponent },
                                        cwd: first.deletingLastPathComponent())
        }
        return [out]
    }

    static func tarGz(_ url: URL) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: url.lastPathComponent + ".tar.gz") { tmp in
            try await ProcessRunner.run(tarURL, ["-czf", tmp.path, "-C", url.deletingLastPathComponent().path, url.lastPathComponent])
        }
        return [out]
    }

    static func gzip(_ url: URL) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: url.lastPathComponent + ".gz") { tmp in
            try await ProcessRunner.run(gzipURL, ["-c", url.path], stdoutTo: tmp)
        }
        return [out]
    }

    static func extract(_ url: URL) async throws -> [URL] {
        let e = FileKind.ext(url)
        if e == "gz" {
            let inner = url.deletingPathExtension().lastPathComponent
            let out = try await OutputManager.produce(source: url, fileName: inner) { tmp in
                try await ProcessRunner.run(gzipURL, ["-dc", url.path], stdoutTo: tmp)
            }
            return [out]
        }
        var name = url.deletingPathExtension().lastPathComponent
        if e == "tgz", name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        let dir = try await OutputManager.produceFolder(source: url, name: name) { tmp in
            if e == "zip" {
                try await ProcessRunner.run(unzipURL, ["-q", url.path, "-d", tmp.path])
            } else {
                try await ProcessRunner.run(tarURL, ["-xf", url.path, "-C", tmp.path])
            }
            try ArchiveSafety.verify(tmp)
        }
        return [dir]
    }
}

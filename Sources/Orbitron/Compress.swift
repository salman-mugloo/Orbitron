import AVFoundation
import AppKit
import ImageIO
import PDFKit

// MARK: - Duration lookup (ffprobe if present, otherwise AVFoundation)

enum MediaInfo {
    static func duration(_ url: URL) async throws -> Double {
        if let ff = FFmpeg.path {
            let probe = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: probe.path) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbitron-dur-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try? await ProcessRunner.run(probe, ["-v", "error", "-show_entries", "format=duration",
                                                     "-of", "default=noprint_wrappers=1:nokey=1", url.path], stdoutTo: tmp)
                if let s = try? String(contentsOf: tmp, encoding: .utf8),
                   let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 { return d }
            }
        }
        let asset = AVURLAsset(url: url)
        let t = try await asset.load(.duration)
        let s = CMTimeGetSeconds(t)
        if s.isFinite && s > 0 { return s }
        throw EngineError.failed("Couldn't read the length of “\(url.lastPathComponent)”.")
    }
}

// MARK: - Compress to a target size

extension Convert {
    private static func findBinary(_ name: String) -> URL? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/opt/local/bin/", "/usr/bin/"]
            .map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var ghostscript: URL? { findBinary("gs") }

    static func fileSize(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func human(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Entry point used by the Compress panel.
    static func compress(_ url: URL, targetBytes: Int) async throws -> [URL] {
        let ext = FileKind.ext(url)
        if FileKind.imageExt.contains(ext) { return try await compressImage(url, target: targetBytes) }
        if ext == "pdf" { return try await compressPDF(url, target: targetBytes) }
        if FileKind.videoExt.contains(ext) { return try await compressVideo(url, target: targetBytes) }
        if FileKind.audioExt.contains(ext) { return try await compressAudio(url, target: targetBytes) }
        throw EngineError.failed("Size-targeted compression isn't available for .\(ext) files. Use Zip instead.")
    }

    // MARK: Images – lower JPEG quality first, then shrink pixels

    private static func flattenAlpha(_ img: CGImage) -> CGImage {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return img
        default: break
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(img, in: r)
        return ctx.makeImage() ?? img
    }

    private static func jpegData(_ img: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func compressImage(_ url: URL, target: Int) async throws -> [URL] {
        var smallest = Int.max
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "_compressed.jpg") { tmp in
            for scale in [1.0, 0.85, 0.7, 0.55, 0.4, 0.28, 0.18] {
                try Task.checkCancellation()
                let img = flattenAlpha(try ImageEngine.load(url, scale: scale))
                guard let floor = jpegData(img, quality: 0.05) else { throw EngineError.failed("Couldn't encode the image.") }
                smallest = min(smallest, floor.count)
                if floor.count > target { continue }          // even the lowest quality is too big: shrink pixels
                var lo = 0.05, hi = 0.95
                var good = floor
                for _ in 0..<7 {
                    let mid = (lo + hi) / 2
                    if let d = jpegData(img, quality: mid), d.count <= target { good = d; lo = mid } else { hi = mid }
                }
                try good.write(to: tmp)
                return
            }
            throw EngineError.failed("Couldn't get below \(human(target)). The smallest this image gets is about \(human(smallest)).")
        }
        return [out]
    }

    // MARK: PDF – Ghostscript ladder, or rebuild pages as images

    private static func compressPDF(_ url: URL, target: Int) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "_compressed.pdf") { tmp in
            var best = Int.max
            if let gs = ghostscript {
                let levels: [(String, Int?)] = [("/printer", nil), ("/ebook", nil), ("/screen", nil), ("/screen", 50), ("/screen", 36)]
                for (preset, dpi) in levels {
                    try Task.checkCancellation()
                    var args = ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dPDFSETTINGS=" + preset,
                                "-dNOPAUSE", "-dQUIET", "-dBATCH"]
                    if let d = dpi {
                        args += ["-dDownsampleColorImages=true", "-dDownsampleGrayImages=true", "-dDownsampleMonoImages=true",
                                 "-dColorImageResolution=\(d)", "-dGrayImageResolution=\(d)", "-dMonoImageResolution=\(d)"]
                    }
                    args += ["-sOutputFile=" + tmp.path, url.path]
                    try await ProcessRunner.run(gs, args)
                    let size = fileSize(tmp)
                    best = min(best, size)
                    if size <= target { return }
                }
            } else {
                let ladder: [(CGFloat, Double)] = [(1.5, 0.7), (1.3, 0.55), (1.1, 0.45), (0.9, 0.35), (0.7, 0.3), (0.5, 0.25)]
                for (scale, quality) in ladder {
                    try Task.checkCancellation()
                    try rebuildAsImages(url, to: tmp, scale: scale, quality: quality)
                    let size = fileSize(tmp)
                    best = min(best, size)
                    if size <= target { return }
                }
            }
            throw EngineError.failed("Couldn't get below \(human(target)). The smallest this PDF gets is about \(human(best)).")
        }
        return [out]
    }

    private static func rebuildAsImages(_ url: URL, to tmp: URL, scale: CGFloat, quality: Double) throws {
        let doc = try PDFEngine.open(url)
        let result = PDFDocument()
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let size = page.bounds(for: .mediaBox).size
            let cg = try PDFEngine.render(page, scale: scale)
            guard let data = jpegData(cg, quality: quality), let img = NSImage(data: data) else {
                throw EngineError.failed("Couldn't encode a page.")
            }
            img.size = size
            guard let newPage = PDFPage(image: img) else { throw EngineError.failed("Couldn't rebuild a page.") }
            result.insert(newPage, at: result.pageCount)
        }
        guard result.write(to: tmp) else { throw EngineError.failed("Couldn't write the compressed PDF.") }
    }

    // MARK: Video – bitrate from target size and duration

    private static func compressVideo(_ url: URL, target: Int) async throws -> [URL] {
        let dur = try await MediaInfo.duration(url)
        let audioK = 96
        var factor = 0.93
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "_compressed.mp4") { tmp in
            for _ in 0..<3 {
                try Task.checkCancellation()
                let totalK = Double(target) * 8 * factor / dur / 1000
                let videoK = Int(totalK) - audioK
                guard videoK >= 40 else {
                    let minBytes = Int(Double(audioK + 40) * 1000 * dur / 8)
                    throw EngineError.failed("That's too small for a \(Int(dur)) s video. Try at least \(human(minBytes)).")
                }
                let width = videoK < 300 ? 480 : (videoK < 800 ? 720 : (videoK < 2000 ? 1080 : 3840))
                let args = ["-vf", "scale='min(\(width),iw)':-2", "-c:v", "libx264", "-preset", "veryfast",
                            "-b:v", "\(videoK)k", "-maxrate", "\(videoK * 5 / 4)k", "-bufsize", "\(videoK * 2)k",
                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(audioK)k", "-movflags", "+faststart"]
                try await FFmpeg.run(input: url, output: tmp, args: args)
                let size = fileSize(tmp)
                if size <= target { return }
                factor *= Double(target) / Double(max(size, 1)) * 0.97
            }
            throw EngineError.failed("Couldn't reach \(human(target)). Try a slightly larger target.")
        }
        return [out]
    }

    // MARK: Audio – bitrate from target size and duration

    private static func compressAudio(_ url: URL, target: Int) async throws -> [URL] {
        let dur = try await MediaInfo.duration(url)
        let useMP3 = FileKind.ext(url) == "mp3"
        let ext = useMP3 ? "mp3" : "m4a"
        var factor = 0.96
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "_compressed." + ext) { tmp in
            for _ in 0..<3 {
                try Task.checkCancellation()
                let kbps = min(320, Int(Double(target) * 8 * factor / dur / 1000))
                guard kbps >= 16 else {
                    let minBytes = Int(16.0 * 1000 * dur / 8)
                    throw EngineError.failed("That's too small for \(Int(dur)) s of audio. Try at least \(human(minBytes)).")
                }
                let codec = useMP3 ? ["-c:a", "libmp3lame"] : ["-c:a", "aac"]
                try await FFmpeg.run(input: url, output: tmp, args: ["-vn"] + codec + ["-b:a", "\(kbps)k"])
                let size = fileSize(tmp)
                if size <= target { return }
                factor *= Double(target) / Double(max(size, 1)) * 0.97
            }
            throw EngineError.failed("Couldn't reach \(human(target)). Try a slightly larger target.")
        }
        return [out]
    }
}

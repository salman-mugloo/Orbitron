import AppKit
import Foundation

/// One directional conversion route: "files accepted by `accepts` can become `to`".
struct Route {
    let to: String
    let title: String
    let accepts: (URL) -> Bool
    let available: () -> Bool
    let make: (URL) -> JobSpec
}

/// Decides which wheel options exist for a given selection.
/// Only routes whose engine is actually present are offered.
enum Registry {
    static func operations(for mode: Mode, files: [URL]) -> [Operation] {
        guard !files.isEmpty else { return [] }
        switch mode {
        case .convert: return convertOps(files)
        case .tools: return toolOps(files)
        case .actions: return actionOps(files)
        }
    }

    // MARK: - Convert

    static let routes: [Route] = buildRoutes()

    static func route(for url: URL, to: String) -> Route? {
        let e = FileKind.ext(url)
        return routes.first { $0.to == to && $0.accepts(url) && e != to && $0.available() }
    }

    private static func exts(_ s: Set<String>) -> (URL) -> Bool {
        { s.contains(FileKind.ext($0)) }
    }

    private static func job(_ u: URL, _ to: String, _ work: @escaping @Sendable () async throws -> [URL]) -> JobSpec {
        JobSpec(title: "\(u.lastPathComponent) → \(to.uppercased())", work: work)
    }

    private static func buildRoutes() -> [Route] {
        var r: [Route] = []
        func add(_ to: String,
                 accepts: @escaping (URL) -> Bool,
                 available: @escaping () -> Bool = { true },
                 make: @escaping (URL) -> JobSpec) {
            r.append(Route(to: to, title: to.uppercased(), accepts: accepts, available: available, make: make))
        }
        let ffmpegOK: () -> Bool = { FFmpeg.path != nil }
        let officeOK: () -> Bool = { Office.path != nil }
        let officeIn = FileKind.textutilIn.subtracting(["txt", "html", "webarchive", "rtfd"])
            .union(FileKind.sheetExt).union(FileKind.slidesExt)
        let docIn = FileKind.textutilIn.union(["md"])
        let img = FileKind.imageExt

        // Images
        for to in ["jpg", "png", "heic"] {
            add(to, accepts: exts(img), available: { ImageEngine.canWrite(to) }) { u in
                job(u, to) { try await Convert.image(u, to: to) }
            }
        }
        add("pdf", accepts: exts(img)) { u in
            job(u, "pdf") { try await Convert.imagesToPDF([u]) }
        }
        for to in ["tiff", "bmp", "gif"] {
            add(to, accepts: exts(img), available: { ImageEngine.canWrite(to) }) { u in
                job(u, to) { try await Convert.image(u, to: to) }
            }
        }
        add("webp", accepts: exts(img), available: { FFmpeg.hasEncoder("libwebp") }) { u in
            job(u, "webp") { try await Convert.imageViaFFmpeg(u, to: "webp") }
        }
        add("avif", accepts: exts(img), available: { FFmpeg.hasEncoder("libaom-av1") || FFmpeg.hasEncoder("libsvtav1") }) { u in
            job(u, "avif") { try await Convert.imageViaFFmpeg(u, to: "avif") }
        }

        // SVG
        for to in ["png", "jpg", "pdf"] {
            add(to, accepts: exts(["svg"])) { u in job(u, to) { try await Convert.svg(u, to: to) } }
        }

        // PDF
        for to in ["png", "jpg"] {
            add(to, accepts: exts(["pdf"])) { u in job(u, to) { try await Convert.pdfToImages(u, ext: to) } }
        }
        add("txt", accepts: exts(["pdf"])) { u in job(u, "txt") { try await Convert.pdfText(u) } }

        // Documents → PDF: LibreOffice when installed (best fidelity), otherwise built-in text layout
        add("pdf", accepts: exts(officeIn), available: officeOK) { u in
            job(u, "pdf") { try await Convert.office(u, to: "pdf") }
        }
        add("pdf", accepts: exts(docIn)) { u in
            job(u, "pdf") { try await Convert.docToPDF(u) }
        }

        // Rich text documents (macOS textutil)
        for to in ["txt", "html", "rtf", "docx"] {
            add(to, accepts: exts(FileKind.textutilIn)) { u in job(u, to) { try await Convert.textutil(u, to: to) } }
        }

        // Markdown
        add("html", accepts: exts(["md"])) { u in
            job(u, "html") { try await Convert.textTransform(u, to: "html", Markdown.toHTML) }
        }
        add("docx", accepts: exts(["md"])) { u in job(u, "docx") { try await Convert.markdownVia(u, to: "docx") } }
        add("rtf", accepts: exts(["md"])) { u in job(u, "rtf") { try await Convert.markdownVia(u, to: "rtf") } }
        add("txt", accepts: exts(["md"])) { u in
            job(u, "txt") { try await Convert.textTransform(u, to: "txt", { $0 }) }
        }

        // Spreadsheets and delimited text (XLSX ↔ CSV is built in; XLS/ODS need LibreOffice)
        add("csv", accepts: exts(["xlsx"])) { u in job(u, "csv") { try await Convert.xlsxToCSV(u) } }
        add("csv", accepts: exts(FileKind.sheetExt), available: officeOK) { u in
            job(u, "csv") { try await Convert.office(u, to: "csv") }
        }
        add("xlsx", accepts: exts(["csv", "tsv"])) { u in job(u, "xlsx") { try await Convert.csvToXLSX(u) } }
        add("xlsx", accepts: exts(["ods", "xls"]), available: officeOK) { u in
            job(u, "xlsx") { try await Convert.office(u, to: "xlsx") }
        }
        add("csv", accepts: exts(["tsv"])) { u in
            job(u, "csv") { try await Convert.delimited(u, from: "\t", to: ",", ext: "csv") }
        }
        add("tsv", accepts: exts(["csv"])) { u in
            job(u, "tsv") { try await Convert.delimited(u, from: ",", to: "\t", ext: "tsv") }
        }
        add("json", accepts: exts(["csv", "tsv"])) { u in job(u, "json") { try await Convert.csvToJSON(u) } }
        add("csv", accepts: exts(["json"])) { u in job(u, "csv") { try await Convert.jsonToCSV(u) } }

        // Subtitles
        add("vtt", accepts: exts(["srt"])) { u in
            job(u, "vtt") { try await Convert.textTransform(u, to: "vtt", TextTools.srtToVTT) }
        }
        add("srt", accepts: exts(["vtt"])) { u in
            job(u, "srt") { try await Convert.textTransform(u, to: "srt", TextTools.vttToSRT) }
        }
        add("txt", accepts: exts(["srt", "vtt"])) { u in
            job(u, "txt") { try await Convert.textTransform(u, to: "txt", TextTools.subtitleToText) }
        }

        // Video (registered before audio so video files list video targets first)
        for to in ["mp4", "mov", "mkv", "webm", "avi"] {
            add(to, accepts: exts(FileKind.videoExt), available: ffmpegOK) { u in
                job(u, to) { try await Convert.media(u, to: to) }
            }
        }
        add("gif", accepts: exts(FileKind.videoExt), available: ffmpegOK) { u in
            job(u, "gif") { try await Convert.media(u, to: "gif") }
        }
        add("mp4", accepts: exts(["gif"]), available: ffmpegOK) { u in
            job(u, "mp4") { try await Convert.media(u, to: "mp4") }
        }

        // Audio (and audio extraction from video)
        for to in ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aac"] {
            let fromVideo = ["mp3", "m4a", "wav", "flac", "aac"].contains(to)
            let ok = FileKind.audioExt.union(fromVideo ? FileKind.videoExt : [])
            add(to, accepts: exts(ok), available: ffmpegOK) { u in
                job(u, to) { try await Convert.media(u, to: to) }
            }
        }
        return r
    }

    private static func symbol(for to: String) -> String {
        switch to {
        case "jpg", "png", "heic", "tiff", "bmp", "gif": return "photo"
        case "pdf": return "doc.richtext"
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff": return "waveform"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "csv", "tsv", "xlsx": return "tablecells"
        case "txt", "html", "rtf", "docx", "srt", "vtt": return "doc.text"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private static func convertOps(_ files: [URL]) -> [Operation] {
        var seen = Set<String>()
        var ops: [Operation] = []
        for r in routes {
            guard seen.insert(r.to).inserted else { continue }
            guard files.allSatisfy({ route(for: $0, to: r.to) != nil }) else { continue }
            let to = r.to
            let help = to == "pdf"
                ? "One PDF per file. Use Tools to combine several into one."
                : "Save a \(r.title) copy next to the original."
            ops.append(Operation(
                id: "convert." + to, title: r.title, symbol: symbol(for: to), help: help,
                kind: .jobs({ urls in urls.compactMap { route(for: $0, to: to)?.make($0) } })))
        }
        return ops
    }

    // MARK: - Tools

    private static func perFile(_ title: String, _ work: @escaping @Sendable (URL) async throws -> [URL]) -> OpKind {
        .jobs({ urls in urls.map { u in JobSpec(title: "\(title): \(u.lastPathComponent)") { try await work(u) } } })
    }

    private static func toolOps(_ files: [URL]) -> [Operation] {
        var ops: [Operation] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ help: String, _ kind: OpKind) {
            ops.append(Operation(id: "tool." + id, title: title, symbol: symbol, help: help, kind: kind))
        }
        let images = FileKind.all(files, in: FileKind.imageExt)
        let pdfs = FileKind.all(files, in: ["pdf"])
        let videos = FileKind.all(files, in: FileKind.videoExt)
        let audios = FileKind.all(files, in: FileKind.audioExt)
        let ffmpegOK = FFmpeg.path != nil

        let singleKind = images || pdfs || ((videos || audios) && ffmpegOK)
        if singleKind {
            add("compress", "Compress", "arrow.down.right.and.arrow.up.left",
                "Choose how large the result should be (KB or MB).",
                .immediate({ urls in CompressPanel.show(urls) }))
        }

        if images {
            add("half", "Half size", "arrow.up.left.and.arrow.down.right",
                "Save a copy at 50% of the pixel dimensions.",
                perFile("Resize") { u in
                    let e = FileKind.ext(u)
                    let out = ImageEngine.canWrite(e) ? e : "png"
                    return try await Convert.image(u, to: out, scale: 0.5, suffix: "_50")
                })
            add("strip", "Strip metadata", "eraser",
                "Save a copy without EXIF, GPS or camera data.",
                perFile("Strip metadata") { u in
                    let e = FileKind.ext(u)
                    let out = ImageEngine.canWrite(e) ? e : "png"
                    return try await Convert.image(u, to: out, suffix: "_clean", quality: Prefs.jpegQuality)
                })
            add("qr", "Read QR", "qrcode", "Look for a QR code and copy its contents.",
                .immediate({ urls in readQR(urls[0]) }))
            add("meta", "Metadata", "info.circle", "Show the embedded metadata of the first image.",
                .immediate({ urls in
                    Dialogs.text("Metadata — \(urls[0].lastPathComponent)", ImageEngine.metadata(urls[0]))
                }))
            if files.count > 1 {
                add("combine", "Combine → PDF", "doc.on.doc", "Put all images into one PDF, in selection order.",
                    .jobs({ urls in
                        [JobSpec(title: "Combine \(urls.count) images → PDF") { try await Convert.imagesToPDF(urls, suffix: "_combined") }]
                    }))
            }
        }

        if pdfs {
            if files.count > 1 {
                add("merge", "Merge PDFs", "arrow.triangle.merge", "Join the PDFs into one, in selection order.",
                    .jobs({ urls in [JobSpec(title: "Merge \(urls.count) PDFs") { try await Convert.mergePDFs(urls) }] }))
            }
            add("split", "Split pages", "scissors", "Save each page as its own PDF in a new folder.",
                perFile("Split") { try await Convert.splitPDF($0) })
        }

        if videos && ffmpegOK {
            add("mute", "Mute", "speaker.slash", "Save a copy with the audio removed.",
                perFile("Mute") { u in
                    try await Convert.ffmpeg(u, to: "mp4", args: ["-c:v", "copy", "-an"], suffix: "_muted")
                })
            add("snap", "Snapshot", "camera", "Save the first frame as a PNG.",
                perFile("Snapshot") { u in
                    try await Convert.ffmpeg(u, to: "png", args: ["-frames:v", "1"], suffix: "_frame")
                })
        }

        if audios && ffmpegOK {
            add("trim", "Trim…", "scissors", "Open the waveform editor to cut the start and end.",
                .immediate({ urls in AudioEditors.open(.trim, urls[0]) }))
            add("channels", "Channels…", "speaker.wave.2", "Mono or stereo, with left/right levels and a preview.",
                .immediate({ urls in AudioEditors.open(.channels, urls[0]) }))
            add("bleep", "Bleep…", "waveform.path", "Mark sections of the waveform to cover with a bleep.",
                .immediate({ urls in AudioEditors.open(.bleep, urls[0]) }))
            add("normalize", "Normalize", "slider.horizontal.3", "Even out loudness (EBU R128) into a new file.",
                perFile("Normalize") { u in
                    let e = FFmpeg.audioExts.contains(FileKind.ext(u)) ? FileKind.ext(u) : "m4a"
                    let args = ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] + FFmpeg.audioArgs(e)
                    return try await Convert.ffmpeg(u, to: e, args: args, suffix: "_normalized")
                })
        }

        // Archives
        let archiveExts: Set<String> = ["zip", "tar", "tgz", "gz"]
        if FileKind.all(files, in: archiveExts) {
            add("extract", "Extract", "arrow.up.bin", "Unpack into a new folder (unsafe paths are rejected).",
                perFile("Extract") { try await Convert.extract($0) })
        }
        add("zip", "Zip", "doc.zipper", "Compress into a .zip next to each item (works for any file or folder).", perFile("Zip") { try await Convert.zip($0) })
        if Set(files.map { $0.deletingLastPathComponent().path }).count == 1, files.count > 1 {
            add("ziptog", "Zip together", "shippingbox", "Put all selected items in one Archive.zip.",
                .jobs({ urls in [JobSpec(title: "Zip \(urls.count) items") { try await Convert.zipTogether(urls) }] }))
        }
        add("targz", "tar.gz", "archivebox", "Make a .tar.gz next to each item.", perFile("tar.gz") { try await Convert.tarGz($0) })
        if !files.contains(where: FileKind.isDirectory) {
            add("gzip", "Gzip", "archivebox", "Compress each file as .gz.", perFile("Gzip") { try await Convert.gzip($0) })
        }
        return ops
    }

    private static func readQR(_ url: URL) {
        Task.detached {
            let found = (try? ImageEngine.qr(url)) ?? []
            await MainActor.run {
                if found.isEmpty {
                    Dialogs.text("No QR code found", "Nothing readable in \(url.lastPathComponent).")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string)
                    Dialogs.text("QR code (copied to clipboard)", found.joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: - Actions

    private static func actionOps(_ files: [URL]) -> [Operation] {
        [
            Operation(id: "act.reveal", title: "Reveal", symbol: "folder", help: "Show the items in Finder.",
                      kind: .immediate({ urls in NSWorkspace.shared.activateFileViewerSelecting(urls) })),
            Operation(id: "act.path", title: "Copy path", symbol: "doc.on.clipboard", help: "Copy the full path(s) to the clipboard.",
                      kind: .immediate({ urls in
                          NSPasteboard.general.clearContents()
                          NSPasteboard.general.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
                      })),
            Operation(id: "act.float", title: "Float", symbol: "pin", help: "Keep references on a floating shelf to drag later.",
                      kind: .immediate({ urls in FloatShelf.shared.add(urls) })),
            Operation(id: "act.airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right", help: "Open the AirDrop sharing sheet.",
                      kind: .immediate({ urls in
                          NSApp.activate(ignoringOtherApps: true)
                          NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
                      })),
            Operation(id: "act.copy", title: "Copy to…", symbol: "doc.on.doc", help: "Copy the items to a folder you choose.",
                      kind: .immediate({ urls in transfer(urls, move: false) })),
            Operation(id: "act.move", title: "Move to…", symbol: "arrow.right.circle", help: "Move the items to a folder you choose.",
                      kind: .immediate({ urls in transfer(urls, move: true) })),
            Operation(id: "act.terminal", title: "Terminal", symbol: "terminal", help: "Open the containing folder in your terminal app.",
                      kind: .immediate({ urls in openTerminal(urls[0]) })),
        ]
    }

    @MainActor
    private static func transfer(_ urls: [URL], move: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = move ? "Move Here" : "Copy Here"
        guard p.runModal() == .OK, let dir = p.url else { return }
        let verb = move ? "Move" : "Copy"
        let specs = urls.map { u in
            JobSpec(title: "\(verb): \(u.lastPathComponent)") {
                let dest = OutputManager.freeURL(name: u.lastPathComponent, in: dir)
                if move { try FileManager.default.moveItem(at: u, to: dest) }
                else { try FileManager.default.copyItem(at: u, to: dest) }
                return [dest]
            }
        }
        JobManager.shared.enqueue(specs)
    }

    @MainActor
    private static func openTerminal(_ first: URL) {
        let dir = FileKind.isDirectory(first) ? first : first.deletingLastPathComponent()
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: Prefs.terminalBundleID) {
            ws.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSSound.beep()
        }
    }
}

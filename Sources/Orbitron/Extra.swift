import AppKit
import CoreText
import Foundation
import PDFKit

// MARK: - Markdown → HTML (small built-in converter)

enum Markdown {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var t = esc(s)
        t = t.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*(.+?)\\*", with: "<i>$1</i>", options: .regularExpression)
        t = t.replacingOccurrences(of: "`(.+?)`", with: "<code>$1</code>", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[(.+?)\\]\\((.+?)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return t
    }

    static func toHTML(_ md: String) -> String {
        var out: [String] = []
        var para: [String] = []
        var list: String?
        var inCode = false
        var code: [String] = []

        func flushPara() {
            if !para.isEmpty { out.append("<p>" + inline(para.joined(separator: " ")) + "</p>"); para = [] }
        }
        func closeList() {
            if let l = list { out.append("</\(l)>"); list = nil }
        }
        func item(_ kind: String, _ text: String) {
            flushPara()
            if list != kind { closeList(); out.append("<\(kind)>"); list = kind }
            out.append("<li>" + inline(text) + "</li>")
        }

        for raw in TextTools.lines(md) {
            if raw.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>" + esc(code.joined(separator: "\n")) + "</code></pre>")
                    code = []; inCode = false
                } else {
                    flushPara(); closeList(); inCode = true
                }
                continue
            }
            if inCode { code.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); closeList(); continue }
            if let m = line.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara(); closeList()
                let level = line.distance(from: m.lowerBound, to: m.upperBound) - 1
                out.append("<h\(level)>" + inline(String(line[m.upperBound...])) + "</h\(level)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                item("ul", String(line.dropFirst(2)))
            } else if let m = line.range(of: "^\\d+\\. ", options: .regularExpression) {
                item("ol", String(line[m.upperBound...]))
            } else if line.hasPrefix("> ") {
                flushPara(); closeList()
                out.append("<blockquote>" + inline(String(line.dropFirst(2))) + "</blockquote>")
            } else if line == "---" || line == "***" {
                flushPara(); closeList(); out.append("<hr>")
            } else {
                closeList(); para.append(line)
            }
        }
        if inCode { out.append("<pre><code>" + esc(code.joined(separator: "\n")) + "</code></pre>") }
        flushPara(); closeList()
        return "<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica;font-size:14px;line-height:1.5}code,pre{font-family:Menlo}</style></head><body>"
            + out.joined(separator: "\n") + "</body></html>"
    }
}

// MARK: - Documents → PDF with CoreText (no LibreOffice needed)

enum DocPDF {
    @MainActor
    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = FileKind.ext(url)
        if ext == "md" {
            let html = Markdown.toHTML(try TextTools.read(url))
            return try NSAttributedString(
                data: Data(html.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        }
        if ext == "txt" {
            return NSAttributedString(string: try TextTools.read(url),
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        let type: NSAttributedString.DocumentType
        switch ext {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "rtf": type = .rtf
        case "rtfd": type = .rtfd
        case "html": type = .html
        case "odt": type = .openDocument
        case "webarchive": type = .webArchive
        default: throw EngineError.unreadable(url.lastPathComponent)
        }
        return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    /// Paginates onto A4 pages. Text, fonts and basic styling are kept; images and tables are not laid out.
    static func render(_ text: NSAttributedString, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw EngineError.failed("Couldn't create the PDF.")
        }
        let fs = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let area = box.insetBy(dx: 56, dy: 56)
        var loc = 0
        let total = text.length
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: loc, length: 0), CGPath(rect: area, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            let vis = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if vis.length == 0 { break }
            loc += vis.length
        } while loc < total
        ctx.closePDF()
    }
}

// MARK: - XLSX (read first sheet / write a simple workbook)

final class SharedStringsParser: NSObject, XMLParserDelegate {
    var items: [String] = []
    private var cur = ""
    private var inSI = false
    private var inT = false

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        if e == "si" { cur = ""; inSI = true } else if e == "t", inSI { inT = true }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inT { cur += s } }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        if e == "t" { inT = false } else if e == "si" { items.append(cur); inSI = false }
    }
}

final class SheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    var cells: [Int: [Int: String]] = [:]
    private var rowIdx = 0
    private var colIdx = 0
    private var type = ""
    private var text = ""
    private var inText = false
    private var nextRow = 0

    init(shared: [String]) { self.shared = shared }

    static func column(_ ref: String) -> Int {
        var n = 0
        for u in ref.unicodeScalars {
            guard u.value >= 65 && u.value <= 90 else { break }
            n = n * 26 + Int(u.value - 64)
        }
        return max(0, n - 1)
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        switch e {
        case "row":
            if let r = a["r"], let i = Int(r) { rowIdx = i - 1 } else { rowIdx = nextRow }
            nextRow = rowIdx + 1
            colIdx = 0
        case "c":
            type = a["t"] ?? ""
            if let r = a["r"] { colIdx = SheetParser.column(r) }
            text = ""
        case "v", "t":
            inText = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inText { text += s } }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        switch e {
        case "v", "t": inText = false
        case "c":
            var value = text
            if type == "s", let i = Int(text), i >= 0, i < shared.count { value = shared[i] }
            if type == "b" { value = (text == "1") ? "TRUE" : "FALSE" }
            cells[rowIdx, default: [:]][colIdx] = value
            colIdx += 1
        default: break
        }
    }
}

enum XLSX {
    static func readRows(_ url: URL) async throws -> [[String]] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbitron-x-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", url.path, "-d", dir.path])
        try ArchiveSafety.verify(dir)

        var shared: [String] = []
        if let d = try? Data(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml")) {
            let sp = SharedStringsParser()
            let p = XMLParser(data: d)
            p.delegate = sp
            p.parse()
            shared = sp.items
        }
        let wsDir = dir.appendingPathComponent("xl/worksheets")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: wsDir.path)) ?? [])
            .filter { $0.hasSuffix(".xml") }.sorted()
        guard let name = files.first(where: { $0 == "sheet1.xml" }) ?? files.first else {
            throw EngineError.failed("No worksheet found in this workbook.")
        }
        let data = try Data(contentsOf: wsDir.appendingPathComponent(name))
        let sheet = SheetParser(shared: shared)
        let xp = XMLParser(data: data)
        xp.delegate = sheet
        xp.parse()

        let maxRow = (sheet.cells.keys.max() ?? -1) + 1
        let maxCol = (sheet.cells.values.flatMap { $0.keys }.max() ?? -1) + 1
        var rows: [[String]] = []
        for r in 0..<maxRow {
            let row = sheet.cells[r] ?? [:]
            rows.append((0..<maxCol).map { row[$0] ?? "" })
        }
        return rows
    }

    private static func colName(_ i: Int) -> String {
        var n = i + 1
        var s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n /= 26 }
        return s
    }

    static func write(_ rows: [[String]], to url: URL) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orbitron-w-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func put(_ path: String, _ s: String) throws {
            try s.write(to: dir.appendingPathComponent(path), atomically: false, encoding: .utf8)
        }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        try put("[Content_Types].xml", head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        try put("_rels/.rels", head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        try put("xl/workbook.xml", head + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        try put("xl/_rels/workbook.xml.rels", head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")

        var sheet = head + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (ri, row) in rows.enumerated() {
            sheet += "<row r=\"\(ri + 1)\">"
            for (ci, f) in row.enumerated() where !f.isEmpty {
                let ref = colName(ci) + String(ri + 1)
                if let d = Double(f), d.isFinite, String(d) == f || String(Int(exactly: d) ?? 0) == f {
                    sheet += "<c r=\"\(ref)\"><v>\(f)</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(Markdown.esc(f))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        try put("xl/worksheets/sheet1.xml", sheet)

        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/zip"),
                                    ["-X", "-r", "-nw", url.path, "[Content_Types].xml", "_rels", "xl"], cwd: dir)
    }
}

// MARK: - JSON helpers

enum JSONTable {
    static func infer(_ v: String) -> Any {
        if let i = Int(v), String(i) == v { return i }
        if let d = Double(v), d.isFinite, String(d) == v { return d }
        if v == "true" { return true }
        if v == "false" { return false }
        return v
    }

    static func cell(_ v: Any) -> String {
        if let s = v as? String { return s }
        if v is NSNull { return "" }
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : "\(n)"
        }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
            return String(decoding: d, as: UTF8.self)
        }
        return "\(v)"
    }

    static func rows(fromJSON data: Data) throws -> [[String]] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var items: [Any]
        if let a = obj as? [Any] { items = a } else { items = [obj] }
        guard !items.isEmpty else { throw EngineError.empty }
        var headers: [String] = []
        var seen = Set<String>()
        for it in items {
            if let d = it as? [String: Any] {
                for k in d.keys.sorted() where seen.insert(k).inserted { headers.append(k) }
            }
        }
        if headers.isEmpty { return [["value"]] + items.map { [cell($0)] } }
        var rows = [headers]
        for it in items {
            let d = it as? [String: Any] ?? [:]
            rows.append(headers.map { h in d[h].map(cell) ?? "" })
        }
        return rows
    }
}

// MARK: - More conversion jobs

extension Convert {
    /// WebP / AVIF output: decode with ImageIO (so HEIC etc. work), encode with ffmpeg.
    static func imageViaFFmpeg(_ url: URL, to ext: String) async throws -> [URL] {
        let q = Int(Prefs.jpegQuality * 100)
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
            let png = tmp.deletingLastPathComponent().appendingPathComponent(".orbitron-src-" + UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: png) }
            try ImageEngine.write(try ImageEngine.load(url), ext: "png", quality: 1, to: png)
            let args: [String]
            if ext == "webp" {
                args = ["-c:v", "libwebp", "-quality", String(q), "-frames:v", "1"]
            } else if FFmpeg.hasEncoder("libaom-av1") {
                args = ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "30", "-b:v", "0", "-cpu-used", "6", "-frames:v", "1"]
            } else {
                args = ["-c:v", "libsvtav1", "-crf", "30", "-frames:v", "1"]
            }
            try await FFmpeg.run(input: png, output: tmp, args: args)
        }
        return [out]
    }

    /// SVG → PNG / JPG / PDF by rasterising with AppKit (about 1024 px on the long side, at least 1×).
    static func svg(_ url: URL, to ext: String) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
            let cg: CGImage = try await MainActor.run {
                guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else {
                    throw EngineError.unreadable(url.lastPathComponent)
                }
                let scale = min(16, max(1, 1024 / max(img.size.width, img.size.height)))
                let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let gc = NSGraphicsContext(bitmapImageRep: rep) else {
                    throw EngineError.failed("Couldn't rasterise the SVG.")
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gc
                img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                guard let cg = rep.cgImage else { throw EngineError.failed("Couldn't rasterise the SVG.") }
                return cg
            }
            if ext == "pdf" {
                let doc = PDFDocument()
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                guard let page = PDFPage(image: ns) else { throw EngineError.failed("Couldn't build the PDF.") }
                doc.insert(page, at: 0)
                guard doc.write(to: tmp) else { throw EngineError.failed("Couldn't write the PDF.") }
            } else {
                try ImageEngine.write(cg, ext: ext, quality: Prefs.jpegQuality, to: tmp)
            }
        }
        return [out]
    }

    static func docToPDF(_ url: URL) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + ".pdf") { tmp in
            let text = try await MainActor.run { try DocPDF.load(url) }
            try DocPDF.render(text, to: tmp)
        }
        return [out]
    }

    /// Markdown → DOCX / RTF by way of HTML and `textutil`.
    static func markdownVia(_ url: URL, to ext: String) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + "." + ext) { tmp in
            let html = tmp.deletingLastPathComponent().appendingPathComponent(".orbitron-md-" + UUID().uuidString + ".html")
            defer { try? FileManager.default.removeItem(at: html) }
            try Markdown.toHTML(try TextTools.read(url)).write(to: html, atomically: false, encoding: .utf8)
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/textutil"),
                                        ["-convert", ext, "-output", tmp.path, html.path])
        }
        return [out]
    }

    static func xlsxToCSV(_ url: URL) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + ".csv") { tmp in
            let rows = try await XLSX.readRows(url)
            try TextTools.writeCSV(rows, delimiter: ",").write(to: tmp, atomically: false, encoding: .utf8)
        }
        return [out]
    }

    static func csvToXLSX(_ url: URL) async throws -> [URL] {
        let delim: Character = FileKind.ext(url) == "tsv" ? "\t" : ","
        let out = try await OutputManager.produce(source: url, fileName: base(url) + ".xlsx") { tmp in
            let rows = TextTools.parseCSV(try TextTools.read(url), delimiter: delim)
            guard !rows.isEmpty else { throw EngineError.empty }
            try await XLSX.write(rows, to: tmp)
        }
        return [out]
    }

    static func csvToJSON(_ url: URL) async throws -> [URL] {
        let delim: Character = FileKind.ext(url) == "tsv" ? "\t" : ","
        let out = try await OutputManager.produce(source: url, fileName: base(url) + ".json") { tmp in
            let rows = TextTools.parseCSV(try TextTools.read(url), delimiter: delim)
            guard let header = rows.first, rows.count > 1 else { throw EngineError.empty }
            let objs: [[String: Any]] = rows.dropFirst().map { r in
                var d: [String: Any] = [:]
                for (i, h) in header.enumerated() { d[h] = JSONTable.infer(i < r.count ? r[i] : "") }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: objs, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: tmp)
        }
        return [out]
    }

    static func jsonToCSV(_ url: URL) async throws -> [URL] {
        let out = try await OutputManager.produce(source: url, fileName: base(url) + ".csv") { tmp in
            let rows = try JSONTable.rows(fromJSON: try Data(contentsOf: url))
            try TextTools.writeCSV(rows, delimiter: ",").write(to: tmp, atomically: false, encoding: .utf8)
        }
        return [out]
    }
}

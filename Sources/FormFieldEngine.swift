// Form authoring: create AcroForm fields (text, checkbox, radio, dropdown) and repair
// the /AcroForm catalog entry that PDFKit's writer never emits for authored widgets.
//
// Ground truth (2026-08-29 probes):
// - PDFKit writes fully-formed widget FIELD dicts (/T /FT /Ff /V /AP /Opt) as page
//   annotations, but a fresh PDFDocument's catalog has NO /AcroForm — so Acrobat, Chrome
//   (pdfium) and pdf.js enumerate zero fields even though Preview shows them.
// - Jack's NSDocument save path rebuilds into a fresh PDFDocument, so it drops /AcroForm
//   from real fillable forms too. AcroFormFixup.fix(data:) repairs both cases.
// - Flat same-name radio widgets with distinct /AP states merge into one group in both
//   pypdf and pdf.js (probe-verified); no parent-/Kids surgery needed.
// - The fixup parses ONLY PDFKit-writer output (classic xref, direct dicts) — the same
//   normalization law as AES256PDF. Callers always pass dataRepresentation() output.
import Foundation
import AppKit
import PDFKit

// MARK: - Field factory

enum FormFieldKind {
    case text
    case multiline
    case checkbox
    case radioGroup(options: [String])
    case dropdown(options: [String])
    case date

    var paletteLabel: String {
        switch self {
        case .text: return "Text Field"
        case .multiline: return "Text Box"
        case .checkbox: return "Checkbox"
        case .radioGroup: return "Multiple Choice"
        case .dropdown: return "Dropdown"
        case .date: return "Date"
        }
    }

    var baseName: String {
        switch self {
        case .text: return "Text"
        case .multiline: return "Text Box"
        case .checkbox: return "Checkbox"
        case .radioGroup: return "Choice"
        case .dropdown: return "Dropdown"
        case .date: return "Date"
        }
    }
}

enum FormFieldEngine {
    static let fieldFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)

    /// Build the widget annotation(s) for one field. A radio group returns one widget per
    /// option, stacked downward from the given rect (each row rect.height tall).
    /// 🧨 PDFKit landmine: setting widgetFieldType/widgetControlType RESETS the field name
    /// (/T becomes an auto "text0"). Type and control MUST be set before fieldName.
    static func makeAnnotations(kind: FormFieldKind, name: String, bounds: CGRect) -> [PDFAnnotation] {
        func widget(_ rect: CGRect, _ configureType: (PDFAnnotation) -> Void) -> PDFAnnotation {
            let a = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
            configureType(a)          // field type first — its setter clobbers /T
            a.fieldName = name        // name second, always
            a.font = fieldFont
            a.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.96, blue: 1.0, alpha: 1)
            let b = PDFBorder(); b.lineWidth = 1; a.border = b
            return a
        }
        switch kind {
        case .text, .date:
            return [widget(bounds) { $0.widgetFieldType = .text }]
        case .multiline:
            return [widget(bounds) { $0.widgetFieldType = .text; $0.isMultiline = true }]
        case .checkbox:
            let side = min(max(min(bounds.width, bounds.height), 12), 22)
            return [widget(CGRect(x: bounds.minX, y: bounds.maxY - side, width: side, height: side)) {
                $0.widgetFieldType = .button
                $0.widgetControlType = .checkBoxControl
            }]
        case .radioGroup(let options):
            let side: CGFloat = 16
            let rowHeight = max(bounds.height, 22)
            return options.enumerated().map { i, opt in
                let y = bounds.maxY - side - CGFloat(i) * rowHeight
                return widget(CGRect(x: bounds.minX, y: y, width: side, height: side)) {
                    $0.widgetFieldType = .button
                    $0.widgetControlType = .radioButtonControl
                    $0.buttonWidgetStateString = exportValue(opt, fallbackIndex: i)
                }
            }
        case .dropdown(let options):
            return [widget(bounds) {
                $0.widgetFieldType = .choice
                $0.isListChoice = false
                $0.choices = options
            }]
        }
    }

    /// PDF name-safe export value for a radio option ("Option One" → "Option_One").
    static func exportValue(_ option: String, fallbackIndex: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = String(option.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "Option_\(fallbackIndex + 1)" : cleaned
    }

    /// "Text 3" — first numbered name not already used by a widget in the document.
    static func uniqueName(base: String, in doc: PDFDocument) -> String {
        var used = Set<String>()
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] where a.type == "Widget" {
                if let n = a.fieldName { used.insert(n) }
            }
        }
        var n = 1
        while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    static func hasWidgets(_ doc: PDFDocument) -> Bool {
        for i in 0..<doc.pageCount {
            if doc.page(at: i)?.annotations.contains(where: { $0.type == "Widget" }) == true { return true }
        }
        return false
    }

    /// 🧨 PDFKit landmine: serializing a document built from page.copy() pages drops the
    /// /V + /AS of RADIO widgets (text/checkbox/choice values survive; direct writes of the
    /// original document survive). The live doc knows the truth — collect it here and let
    /// AcroFormFixup re-assert it at the byte level.
    static func radioAsserts(from doc: PDFDocument) -> [RadioStateAssert] {
        var groups: [String: [(PDFAnnotation, CGRect)]] = [:]
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] where a.widgetControlType == .radioButtonControl {
                guard let name = a.fieldName else { continue }
                groups[name, default: []].append((a, a.bounds))
            }
        }
        var asserts: [RadioStateAssert] = []
        for (name, widgets) in groups {
            guard let chosen = widgets.first(where: { $0.0.buttonWidgetState == .onState })?.0.buttonWidgetStateString,
                  !chosen.isEmpty else { continue }
            for (a, rect) in widgets {
                asserts.append(RadioStateAssert(fieldName: name, rect: rect,
                                                ownState: a.buttonWidgetStateString, chosenState: chosen))
            }
        }
        return asserts
    }
}

struct RadioStateAssert {
    let fieldName: String
    let rect: CGRect
    let ownState: String
    let chosenState: String
}

// MARK: - /AcroForm fixup

enum AcroFormFixup {
    /// Repair the catalog of PDFKit-writer output so widget annotations are real AcroForm
    /// fields everywhere (Acrobat/Chrome/pdf.js), via an appended incremental update.
    /// radioAsserts re-writes radio /V + /AS lost by the page-copy serialization path
    /// (matched by /T + /Rect; every group widget gets /V chosen, /AS own-or-Off).
    /// Fail-open: any parse anomaly returns the input unchanged — a save is never corrupted.
    static func fix(data: Data, radioAsserts: [RadioStateAssert] = []) -> Data {
        // Latin-1 gives a 1:1 byte↔UTF-16-unit mapping, so NSRange offsets == byte offsets.
        guard let s = String(data: data, encoding: .isoLatin1) else { return data }
        let ns = s as NSString

        func firstMatch(_ pattern: String, in range: NSRange? = nil) -> NSTextCheckingResult? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return re.firstMatch(in: s, options: [], range: range ?? NSRange(location: 0, length: ns.length))
        }
        func allMatches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        }

        // Trailer (last one) + startxref.
        let trailerLoc = ns.range(of: "trailer", options: .backwards)
        guard trailerLoc.location != NSNotFound else { return data }
        let tail = NSRange(location: trailerLoc.location, length: ns.length - trailerLoc.location)
        guard let sizeM = firstMatch(#"/Size\s+(\d+)"#, in: tail),
              let rootM = firstMatch(#"/Root\s+(\d+)\s+0\s+R"#, in: tail),
              let sxM = firstMatch(#"startxref\s+(\d+)"#, in: tail),
              let size = Int(ns.substring(with: sizeM.range(at: 1))),
              let rootNum = Int(ns.substring(with: rootM.range(at: 1))),
              let prevXref = Int(ns.substring(with: sxM.range(at: 1))) else { return data }
        let infoM = firstMatch(#"/Info\s+(\d+)\s+0\s+R"#, in: tail)
        let idM = firstMatch(#"/ID\s*(\[[^\]]*\])"#, in: tail)

        // Widget field objects (skip kids-only widgets if any: require /Subtype /Widget).
        var widgetNums: [Int] = []
        var widgetBodies: [(num: Int, body: String)] = []
        for m in allMatches(#"(\d+)\s+0\s+obj(.*?)endobj"#) {
            let body = ns.substring(with: m.range(at: 2))
            if body.contains("/Widget"), let n = Int(ns.substring(with: m.range(at: 1))) {
                widgetNums.append(n)
                widgetBodies.append((n, body))
            }
        }
        guard !widgetNums.isEmpty else { return data }

        // Catalog body.
        guard let catM = firstMatch("(?<![0-9])\(rootNum)\\s+0\\s+obj\\s*<<(.*?)>>\\s*endobj") else { return data }
        let catalogBody = ns.substring(with: catM.range(at: 1))

        var out = data
        if !out.isEmpty && out.last != 0x0A { out.append(0x0A) }

        var appended: [(num: Int, offset: Int, body: String)] = []
        func append(num: Int, _ body: String) {
            appended.append((num, out.count, body))
            out.append(Data("\(num) 0 obj\n\(body)\nendobj\n".utf8))
        }

        let fieldsArray = widgetNums.map { "\($0) 0 R" }.joined(separator: " ")

        if let acroRefM = firstMatch(#"/AcroForm\s+(\d+)\s+0\s+R"#, in: catM.range(at: 1)).map({ $0 }),
           catalogBody.contains("/AcroForm") {
            // Existing AcroForm object: rewrite its /Fields to the full widget set.
            guard let acroNum = Int(ns.substring(with: acroRefM.range(at: 1))),
                  let acroM = firstMatch("(?<![0-9])\(acroNum)\\s+0\\s+obj\\s*<<(.*?)>>\\s*endobj") else { return data }
            var acroBody = ns.substring(with: acroM.range(at: 1))
            if let fieldsRange = acroBody.range(of: #"/Fields\s*\[[^\]]*\]"#, options: .regularExpression) {
                acroBody.replaceSubrange(fieldsRange, with: "/Fields [ \(fieldsArray) ]")
            } else {
                acroBody += " /Fields [ \(fieldsArray) ]"
            }
            append(num: acroNum, "<<\(acroBody)>>")
        } else if catalogBody.contains("/AcroForm") {
            // Inline AcroForm dict in the catalog: rewrite the catalog with fresh /Fields.
            var newCat = catalogBody
            if let acroRange = newCat.range(of: #"/AcroForm\s*<<.*?>>"#, options: .regularExpression) {
                newCat.replaceSubrange(acroRange, with: "/AcroForm << /Fields [ \(fieldsArray) ] /DA (/Helv 0 Tf 0 g) >>")
            }
            append(num: rootNum, "<<\(newCat)>>")
        } else {
            // No AcroForm anywhere (the PDFKit fresh-document case): patched catalog +
            // AcroForm dict + a standard Helvetica for viewers that regenerate appearances.
            let acroNum = size, fontNum = size + 1
            append(num: rootNum, "<< \(catalogBody.trimmingCharacters(in: .whitespacesAndNewlines)) /AcroForm \(acroNum) 0 R >>")
            append(num: acroNum, "<< /Fields [ \(fieldsArray) ] /DR << /Font << /Helv \(fontNum) 0 R >> >> /DA (/Helv 0 Tf 0 g) >>")
            append(num: fontNum, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        }

        // Re-assert radio state on matched widget objects (name + rect, 1pt tolerance).
        if !radioAsserts.isEmpty {
            for (num, body) in widgetBodies {
                guard let tM = body.range(of: #"/T\s*\(([^)]*)\)"#, options: .regularExpression),
                      let rectM = body.range(of: #"/Rect\s*\[([^\]]*)\]"#, options: .regularExpression) else { continue }
                let tName = String(body[tM]).replacingOccurrences(of: #"/T\s*\(|\)$"#, with: "", options: .regularExpression)
                let nums = String(body[rectM]).components(separatedBy: CharacterSet(charactersIn: "[] ")).compactMap(Double.init)
                guard nums.count == 4 else { continue }
                guard let assert = radioAsserts.first(where: {
                    $0.fieldName == tName &&
                    abs(nums[0] - $0.rect.minX) < 1 && abs(nums[1] - $0.rect.minY) < 1 &&
                    abs(nums[2] - $0.rect.maxX) < 1 && abs(nums[3] - $0.rect.maxY) < 1
                }) else { continue }
                let asState = assert.ownState == assert.chosenState ? assert.ownState : "Off"
                var patched = body
                func setName(_ key: String, _ value: String, in b: String) -> String {
                    var s = b
                    if let r = s.range(of: "\(key)\\s*/[^\\s/>\\]]+", options: .regularExpression) {
                        s.replaceSubrange(r, with: "\(key) /\(value)")
                    } else if let close = s.range(of: ">>", options: .backwards) {
                        s.replaceSubrange(close, with: " \(key) /\(value) >>")
                    }
                    return s
                }
                patched = setName("/V", assert.chosenState, in: patched)
                patched = setName("/AS", asState, in: patched)
                if patched != body {
                    append(num: num, patched.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        // Incremental-update xref: one subsection per object, ascending object number.
        let xrefOffset = out.count
        var xref = "xref\n"
        for entry in appended.sorted(by: { $0.num < $1.num }) {
            xref += "\(entry.num) 1\n" + String(format: "%010d 00000 n \n", entry.offset)
        }
        let newSize = max(size, (appended.map { $0.num }.max() ?? 0) + 1)
        var trailer = "trailer\n<< /Size \(newSize) /Root \(rootNum) 0 R /Prev \(prevXref)"
        if let infoM { trailer += " /Info \(ns.substring(with: infoM.range(at: 1))) 0 R" }
        if let idM { trailer += " /ID \(ns.substring(with: idM.range(at: 1)))" }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data((xref + trailer).utf8))
        return out
    }
}

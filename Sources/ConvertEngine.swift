// Convert to PDF — Word documents, rich text, and plain text become clean PDFs, entirely
// on this Mac (JC's ask, 2026-08-30). Drop a file on Jack or right-click it in Finder.
//
// The honest scope: .docx/.doc/.rtf/.rtfd/.txt convert through macOS's native document
// reader and the Cocoa print pipeline (pagination, embedded images, tables, margins all
// handled by the same machinery TextEdit prints with). Spreadsheets and presentations are
// REFUSED with a clear message rather than mangled — fidelity is the product.
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum ConvertEngine {

    static let convertibleExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "txt"]
    static let refusedExtensions: Set<String> = ["xlsx", "xls", "pptx", "ppt", "key", "numbers", "pages"]

    static func isConvertible(_ url: URL) -> Bool {
        convertibleExtensions.contains(url.pathExtension.lowercased())
    }
    static func isRefused(_ url: URL) -> Bool {
        refusedExtensions.contains(url.pathExtension.lowercased())
    }

    enum ConvertError: LocalizedError {
        case unsupported(String)
        case unreadable(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                return "Jack converts Word documents (.docx, .doc), rich text, and plain text. “.\(ext)” files keep their layout best when exported to PDF from the app that made them."
            case .unreadable(let name):
                return "“\(name)” couldn’t be read. If it’s password-protected, remove the password and try again."
            case .writeFailed:
                return "The PDF couldn’t be written."
            }
        }
    }

    /// Where the converted PDF lands: beside the source, never clobbering anything.
    static func outputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(base + ".pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).pdf")
            n += 1
        }
        return candidate
    }

    /// Read the document with Cocoa's native reader, paginate it through the print
    /// pipeline, and write a PDF. Returns the written URL.
    @discardableResult
    static func convertToPDF(_ source: URL, to output: URL? = nil) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard isConvertible(source) else { throw ConvertError.unsupported(ext) }

        var docAttrs: NSDictionary?
        let attr: NSAttributedString
        do {
            attr = try NSAttributedString(url: source, options: [:], documentAttributes: &docAttrs)
        } catch {
            throw ConvertError.unreadable(source.lastPathComponent)
        }

        // Paper geometry: honor the document's own when it declares one, else US Letter, 1".
        let attrs = docAttrs as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        var paper = (attrs[.paperSize] as? NSValue)?.sizeValue ?? NSSize(width: 612, height: 792)
        if paper.width < 200 || paper.height < 200 { paper = NSSize(width: 612, height: 792) }
        let left   = attrs[.leftMargin]   as? CGFloat ?? 72
        let right  = attrs[.rightMargin]  as? CGFloat ?? 72
        let top    = attrs[.topMargin]    as? CGFloat ?? 72
        let bottom = attrs[.bottomMargin] as? CGFloat ?? 72

        // A text view the width of the printable area; the print operation paginates it.
        let contentWidth = max(100, paper.width - left - right)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(attr)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()

        let out = output ?? outputURL(for: source)
        let info = NSPrintInfo()
        info.paperSize = paper
        info.leftMargin = left; info.rightMargin = right
        info.topMargin = top; info.bottomMargin = bottom
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path),
              let check = PDFDocument(url: out), check.pageCount > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.writeFailed
        }
        return out
    }
}

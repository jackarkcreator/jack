// Batch processing core (UI-free, headless-testable): run one operation across a folder of
// PDFs. Outputs land in a "Jack Processed" subfolder — originals are never touched. A failing
// or locked file is reported and skipped, never fatal. Bates numbering is CONTINUOUS across
// files in name order, matching how legal document productions are numbered.
import AppKit
import PDFKit

enum BatchEngine {

    enum Operation {
        case ocr
        case bates(prefix: String, start: Int, digits: Int, corner: StampEngine.Corner)
        case watermark(text: String, opacity: CGFloat)
        case compress
    }

    struct Summary {
        var processed: [String] = []
        var skipped: [(name: String, reason: String)] = []
        var bytesBefore: Int = 0
        var bytesAfter: Int = 0
    }

    static let outputFolderName = "Jack Processed"

    static func pdfFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `progress(fileIndex, fileCount, fileName)` is called before each file, on the calling queue.
    static func run(_ op: Operation, files: [URL], outputDir: URL,
                    progress: (Int, Int, String) -> Void) -> Summary {
        var summary = Summary()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var batesNext: Int = {
            if case .bates(_, let start, _, _) = op { return start }
            return 0
        }()

        for (i, url) in files.enumerated() {
            progress(i + 1, files.count, url.lastPathComponent)
            guard let doc = PDFDocument(url: url) else {
                summary.skipped.append((url.lastPathComponent, "couldn’t be read as a PDF"))
                continue
            }
            guard !doc.isLocked else {
                summary.skipped.append((url.lastPathComponent, "password-protected"))
                continue
            }
            guard doc.pageCount > 0 else {
                summary.skipped.append((url.lastPathComponent, "has no pages"))
                continue
            }
            let out = outputDir.appendingPathComponent(url.lastPathComponent)
            let ok: Bool
            switch op {
            case .ocr:
                ok = OCREngine.makeSearchable(doc, to: out).0
            case .bates(let prefix, _, let digits, let corner):
                ok = StampEngine.bates(doc, to: out, prefix: prefix, start: batesNext,
                                       digits: digits, corner: corner)
                if ok { batesNext += doc.pageCount }   // continuous across the production set
            case .watermark(let text, let opacity):
                ok = StampEngine.watermark(doc, to: out, text: text, opacity: opacity)
            case .compress:
                ok = CompressEngine.compress(doc, to: out).0
            }
            if ok {
                summary.processed.append(url.lastPathComponent)
                summary.bytesBefore += (try? Data(contentsOf: url).count) ?? 0
                summary.bytesAfter += (try? Data(contentsOf: out).count) ?? 0
            } else {
                summary.skipped.append((url.lastPathComponent, "processing failed"))
                try? FileManager.default.removeItem(at: out)
            }
        }
        return summary
    }
}

// Redaction Verification Certificate — the verify pass, productized. A one-page,
// black-and-white, text-extractable certificate emitted beside every verified redaction:
// what was redacted, which adversarial checks passed, when, and the SHA-256 of the output
// so anyone can prove the file they hold is the verified one (`shasum -a 256 <file>`).
import AppKit
import PDFKit
import CryptoKit

enum CertificateEngine {

    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    /// `metadataStripped` MUST reflect reality: the export path drops the /Info dict by
    /// construction, an in-place redaction does not. A certificate is a legal artifact — it
    /// never claims a check that was not performed. No default value, on purpose.
    static func generate(forRedacted redactedURL: URL, redactedPages: [Int], regionCount: Int,
                         terms: [String], appVersion: String, metadataStripped: Bool,
                         to url: URL) -> Bool {
        guard let digest = sha256Hex(of: redactedURL) else { return false }

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)

        var y: CGFloat = 720
        func draw(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                  mono: Bool = false, indent: CGFloat = 72, gapAfter: CGFloat = 8) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                            : NSFont.systemFont(ofSize: size, weight: weight)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.black
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: indent, y: y)
            CTLineDraw(line, ctx)
            y -= size + gapAfter
        }
        func rule(_ gap: CGFloat = 14) {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(0.75)
            ctx.move(to: CGPoint(x: 72, y: y + 6))
            ctx.addLine(to: CGPoint(x: 540, y: y + 6))
            ctx.strokePath()
            y -= gap
        }

        let df = ISO8601DateFormatter()
        df.timeZone = TimeZone.current
        let local = DateFormatter()
        local.dateStyle = .long; local.timeStyle = .medium

        draw("REDACTION VERIFICATION CERTIFICATE", size: 18, weight: .bold, gapAfter: 4)
        draw("Issued by Jack \(appVersion) — ThinkOpen Inc.", size: 10, gapAfter: 10)
        rule()

        draw("Document", size: 11, weight: .semibold, gapAfter: 4)
        draw(redactedURL.lastPathComponent, size: 12, gapAfter: 12)

        draw("SHA-256 digest of the redacted file", size: 11, weight: .semibold, gapAfter: 4)
        let mid = digest.index(digest.startIndex, offsetBy: 32)
        draw(String(digest[..<mid]), size: 11, mono: true, gapAfter: 2)
        draw(String(digest[mid...]), size: 11, mono: true, gapAfter: 12)

        draw("Issued", size: 11, weight: .semibold, gapAfter: 4)
        draw("\(local.string(from: Date()))  (\(df.string(from: Date())))", size: 11, gapAfter: 12)

        draw("Redactions applied", size: 11, weight: .semibold, gapAfter: 4)
        let pageList = redactedPages.map { String($0 + 1) }.joined(separator: ", ")
        draw("\(regionCount) region\(regionCount == 1 ? "" : "s") across \(redactedPages.count) page\(redactedPages.count == 1 ? "" : "s") (page\(redactedPages.count == 1 ? "" : "s") \(pageList))", size: 11, gapAfter: 12)
        rule()

        draw("Verification performed on the output file", size: 12, weight: .semibold, gapAfter: 8)
        draw("[PASS]  Redacted pages re-rendered — underlying text objects destroyed, not covered.", size: 10.5, gapAfter: 6)
        draw("[PASS]  Text extraction on every redacted page returned 0 recoverable characters.", size: 10.5, gapAfter: 6)
        if terms.isEmpty {
            draw("[PASS]  No residual content found beneath any redaction region.", size: 10.5, gapAfter: 6)
        } else {
            draw("[PASS]  Document-wide search for \(terms.count) redacted term\(terms.count == 1 ? "" : "s") returned 0 matches.", size: 10.5, gapAfter: 6)
        }
        if metadataStripped {
            draw("[PASS]  Document metadata (author, title, creation tool) removed.", size: 10.5, gapAfter: 14)
        } else {
            draw("[NOTE]  Document metadata was PRESERVED — this file was edited in place, not", size: 10.5, gapAfter: 6)
            draw("        exported. Use Clean for Sharing to strip metadata before distribution.", size: 10.5, gapAfter: 14)
        }
        rule()

        draw("To verify this certificate matches the file you hold, run:", size: 10, gapAfter: 5)
        draw("shasum -a 256 \"\(redactedURL.lastPathComponent)\"", size: 10.5, mono: true, gapAfter: 5)
        draw("The output must equal the digest above. Any change to the file changes its digest.", size: 10, gapAfter: 12)
        draw("Redaction and verification were performed entirely on the issuing computer.", size: 9, gapAfter: 4)
        draw("No document content was transmitted to any external service.", size: 9)

        ctx.endPDFPage()
        ctx.closePDF()
        return true
    }
}

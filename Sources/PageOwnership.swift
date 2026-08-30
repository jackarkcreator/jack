// 🧨 A PDFPage does NOT keep its PDFDocument alive.
//
// Every engine that builds a replacement page does it by writing a one-page PDF into memory,
// opening it, and returning page 0 — at which point that temporary PDFDocument is released.
// The orphaned page still renders correctly in place, which is what made this so hard to see:
// the erase looked right on screen and the live document measured fine. But `page.copy()` of
// an orphaned page yields a BLANK page, and copying every page is exactly what saving does.
// That is how blank pages reached saved files while nothing looked wrong beforehand.
//
// AppKit logs "Drawing a PDFPage when its PDFDocument is nil is unsupported" when it happens.
// Treat that message as a bug, never as noise.
//
// Fix: pin the backing document to the page, so it lives exactly as long as the page does.
import Foundation
import PDFKit
import ObjectiveC

private var jackBackingDocumentKey: UInt8 = 0

extension PDFPage {
    /// Keep `doc` alive for as long as this page is. Call this on EVERY page handed out by an
    /// engine that built it from a temporary document.
    func retainBackingDocument(_ doc: PDFDocument) {
        objc_setAssociatedObject(self, &jackBackingDocumentKey, doc, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// True when this page has no document to draw from — copying it would produce a blank page.
    var isOrphaned: Bool { document == nil }
}

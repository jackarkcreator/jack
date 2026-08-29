// Ask Your PDF — Apple's on-device foundation model (macOS 26+). The document NEVER leaves
// the Mac: no network, no account, no cloud. The on-device model has a small context window,
// so we chunk the document with page numbers, rank chunks against the question lexically,
// and hand the model only the best excerpts; summaries map-reduce across chunks.
import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AskEngine {

    struct Chunk { let page: Int; let text: String }

    /// True only on macOS 26+ with Apple Intelligence ready. Safe to call anywhere.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    // MARK: - Chunking + lexical ranking (pure, headless-testable)

    static func chunks(from doc: PDFDocument, maxChars: Int = 1600) -> [Chunk] {
        var out: [Chunk] = []
        for i in 0..<doc.pageCount {
            let text = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var rest = Substring(text)
            while !rest.isEmpty {
                let piece = rest.prefix(maxChars)
                // Break at a sentence-ish boundary when possible.
                var cut = piece
                if rest.count > maxChars, let dot = piece.lastIndex(of: ".") , piece.distance(from: piece.startIndex, to: dot) > maxChars / 2 {
                    cut = piece[piece.startIndex...dot]
                }
                out.append(Chunk(page: i + 1, text: String(cut)))
                rest = rest.dropFirst(cut.count)
            }
        }
        return out
    }

    static func rank(_ chunks: [Chunk], for question: String, top: Int = 4) -> [Chunk] {
        let terms = tokenize(question)
        guard !terms.isEmpty else { return Array(chunks.prefix(top)) }
        let scored = chunks.map { chunk -> (Chunk, Int) in
            let words = tokenize(chunk.text)
            var counts: [String: Int] = [:]
            for w in words { counts[w, default: 0] += 1 }
            var score = 0
            for t in terms {
                let weight = max(1, t.count - 3)   // longer terms carry more signal
                score += (counts[t] ?? 0) * weight
            }
            return (chunk, score)
        }
        let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(top).map { $0.0 }
        return hits.isEmpty ? Array(chunks.prefix(top)) : hits
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
    }

    // MARK: - Model calls

    static func answer(question: String, doc: PDFDocument) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return unavailableMessage }
        let all = chunks(from: doc)
        guard !all.isEmpty else { return noTextMessage }
        let picked = rank(all, for: question)
        var excerpts = ""
        var budget = 6000
        for c in picked {
            let piece = "[Page \(c.page)]\n\(c.text)\n\n"
            guard budget - piece.count > 0 else { break }
            excerpts += piece
            budget -= piece.count
        }
        let session = LanguageModelSession(instructions:
            "You answer questions about a PDF document using ONLY the excerpts provided. " +
            "Cite the page number(s) you used, like (p. 3). If the excerpts don't contain the answer, " +
            "say the document doesn't appear to contain it. Be concise.")
        let prompt = "Excerpts from the document:\n\n\(excerpts)\nQuestion: \(question)"
        return try await session.respond(to: prompt).content
        #else
        return unavailableMessage
        #endif
    }

    static func summarize(doc: PDFDocument, progress: @escaping (Int, Int) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return unavailableMessage }
        let all = chunks(from: doc, maxChars: 2800)
        guard !all.isEmpty else { return noTextMessage }
        let capped = Array(all.prefix(12))
        var notes: [String] = []
        for (i, c) in capped.enumerated() {
            progress(i + 1, capped.count)
            let s = LanguageModelSession(instructions:
                "Summarize the excerpt in 1-2 dense sentences. Keep names, amounts, and dates.")
            let r = try await s.respond(to: "[Page \(c.page)]\n\(c.text)")
            notes.append("(p. \(c.page)) " + r.content)
        }
        let final = LanguageModelSession(instructions:
            "Combine the page notes into a clear summary of the whole document: a short paragraph, " +
            "then up to 5 bullet points with the key facts, keeping page citations.")
        var combined = try await final.respond(to: notes.joined(separator: "\n")).content
        if all.count > capped.count {
            combined += "\n\n(Summary covers the first \(capped.last?.page ?? 0) pages of \(doc.pageCount).)"
        }
        return combined
        #else
        return unavailableMessage
        #endif
    }

    static let unavailableMessage = "Ask needs Apple Intelligence (macOS 26 or later)."
    static let noTextMessage = "This document has no readable text — run Tools → Make Searchable (OCR)… first, then ask again."
}

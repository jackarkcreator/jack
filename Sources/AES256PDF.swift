// AES-256 PDF encryption (PDF 2.0 / ISO 32000-2, V=5 R=6 — the scheme Acrobat X+ uses).
// Apple's writer tops out at RC4-128, so Jack brings its own engine. CommonCrypto only.
//
// Scope is deliberately narrow: the rewriter only ever consumes PDFs freshly written by
// PDFKit's own writer (classic xref table, direct /Length, no object/xref streams) — callers
// normalize arbitrary input through PDFDocument.write first. Strings and streams are
// encrypted with AES-256-CBC (random IV prepended, PKCS#7), keys derived per Algorithm 2.B.
import Foundation
import PDFKit
import CommonCrypto

enum AES256PDF {

    // MARK: - Public API

    /// Normalize `doc` through PDFKit's writer, then rewrite it AES-256-encrypted to `url`.
    static func encrypt(_ doc: PDFDocument, to url: URL, userPassword: String, ownerPassword: String) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jack-aes-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard doc.write(to: tmp),
              let plain = try? Data(contentsOf: tmp),
              let out = encryptData(plain, userPassword: userPassword, ownerPassword: ownerPassword) else {
            return false
        }
        do { try out.write(to: url) } catch { return false }
        return true
    }

    /// Encrypt a normalized (PDFKit-written) PDF byte-for-byte. Internal so tests can hit it.
    static func encryptData(_ data: Data, userPassword: String, ownerPassword: String) -> Data? {
        guard let material = EncryptionMaterial(userPassword: userPassword, ownerPassword: ownerPassword) else { return nil }
        return Rewriter(bytes: [UInt8](data)).rewrite(material: material)
    }

    /// Parser gate for tests: re-serialize without touching content. Output must open identically.
    static func identityRewrite(_ data: Data) -> Data? {
        Rewriter(bytes: [UInt8](data)).rewrite(material: nil)
    }

    // MARK: - Crypto primitives

    private static func sha(_ data: [UInt8], bits: Int) -> [UInt8] {
        switch bits {
        case 384:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
            CC_SHA384(data, CC_LONG(data.count), &out); return out
        case 512:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            CC_SHA512(data, CC_LONG(data.count), &out); return out
        default:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(data, CC_LONG(data.count), &out); return out
        }
    }

    private static func aes(_ input: [UInt8], key: [UInt8], iv: [UInt8]?, encrypt: Bool,
                            options: CCOptions) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                             CCAlgorithm(kCCAlgorithmAES), options,
                             key, key.count, iv, input, input.count,
                             &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(out[0..<moved])
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    // Algorithm 2.B — the hardened R6 key derivation.
    private static func hash2B(password: [UInt8], salt: [UInt8], udata: [UInt8]) -> [UInt8] {
        var k = sha(password + salt + udata, bits: 256)
        var round = 0
        var lastE: [UInt8] = []
        while true {
            let block = password + k + udata
            var k1: [UInt8] = []
            k1.reserveCapacity(block.count * 64)
            for _ in 0..<64 { k1 += block }
            guard let e = aes(k1, key: Array(k[0..<16]), iv: Array(k[16..<32]),
                              encrypt: true, options: 0) else { return [] }   // CBC, no padding (multiple of 16)
            lastE = e
            let mod = Int(e[0..<16].reduce(0) { UInt($0) + UInt($1) } % 3)
            k = sha(e, bits: mod == 0 ? 256 : (mod == 1 ? 384 : 512))
            round += 1
            if round >= 64 && Int(lastE.last ?? 255) <= round - 32 { break }
        }
        return Array(k[0..<32])
    }

    // MARK: - Encryption material (file key + U/UE/O/OE/Perms)

    struct EncryptionMaterial {
        let fileKey: [UInt8]
        let u: [UInt8], ue: [UInt8], o: [UInt8], oe: [UInt8], perms: [UInt8]
        let p: Int32 = -4   // all permissions; the password is the control

        init?(userPassword: String, ownerPassword: String) {
            let upw = Array(userPassword.utf8.prefix(127))
            let opw = Array(ownerPassword.utf8.prefix(127))
            fileKey = AES256PDF.randomBytes(32)

            let uValSalt = AES256PDF.randomBytes(8), uKeySalt = AES256PDF.randomBytes(8)
            u = AES256PDF.hash2B(password: upw, salt: uValSalt, udata: []) + uValSalt + uKeySalt
            let uKey = AES256PDF.hash2B(password: upw, salt: uKeySalt, udata: [])
            guard let ueEnc = AES256PDF.aes(fileKey, key: uKey, iv: [UInt8](repeating: 0, count: 16),
                                            encrypt: true, options: 0) else { return nil }
            ue = ueEnc

            let oValSalt = AES256PDF.randomBytes(8), oKeySalt = AES256PDF.randomBytes(8)
            o = AES256PDF.hash2B(password: opw, salt: oValSalt, udata: u) + oValSalt + oKeySalt
            let oKey = AES256PDF.hash2B(password: opw, salt: oKeySalt, udata: u)
            guard let oeEnc = AES256PDF.aes(fileKey, key: oKey, iv: [UInt8](repeating: 0, count: 16),
                                            encrypt: true, options: 0) else { return nil }
            oe = oeEnc

            var permsBlock = [UInt8](repeating: 0, count: 16)
            let pv = UInt32(bitPattern: p)
            permsBlock[0] = UInt8(pv & 0xFF); permsBlock[1] = UInt8((pv >> 8) & 0xFF)
            permsBlock[2] = UInt8((pv >> 16) & 0xFF); permsBlock[3] = UInt8((pv >> 24) & 0xFF)
            permsBlock[4] = 0xFF; permsBlock[5] = 0xFF; permsBlock[6] = 0xFF; permsBlock[7] = 0xFF
            permsBlock[8] = UInt8(ascii: "T")   // EncryptMetadata
            permsBlock[9] = UInt8(ascii: "a"); permsBlock[10] = UInt8(ascii: "d"); permsBlock[11] = UInt8(ascii: "b")
            let rnd = AES256PDF.randomBytes(4)
            permsBlock[12] = rnd[0]; permsBlock[13] = rnd[1]; permsBlock[14] = rnd[2]; permsBlock[15] = rnd[3]
            guard let pe = AES256PDF.aes(permsBlock, key: fileKey, iv: nil, encrypt: true,
                                         options: CCOptions(kCCOptionECBMode)) else { return nil }
            perms = pe
        }

        // AESV3 content encryption: random IV prepended, CBC, PKCS#7.
        func encryptContent(_ plain: [UInt8]) -> [UInt8] {
            let iv = AES256PDF.randomBytes(16)
            let ct = AES256PDF.aes(plain, key: fileKey, iv: iv, encrypt: true,
                                   options: CCOptions(kCCOptionPKCS7Padding)) ?? []
            return iv + ct
        }

        var dictBody: String {
            func hex(_ b: [UInt8]) -> String { "<" + b.map { String(format: "%02x", $0) }.joined() + ">" }
            return "<< /Filter /Standard /V 5 /R 6 /Length 256 /P \(p) /EncryptMetadata true"
                + " /CF << /StdCF << /CFM /AESV3 /Length 32 /AuthEvent /DocOpen >> >>"
                + " /StmF /StdCF /StrF /StdCF"
                + " /U \(hex(u)) /UE \(hex(ue)) /O \(hex(o)) /OE \(hex(oe)) /Perms \(hex(perms)) >>"
        }
    }

    // MARK: - Rewriter (classic-PDF tokenizer for PDFKit-writer output)

    private final class Rewriter {
        let b: [UInt8]
        var i = 0
        var out: [UInt8] = []
        var offsets: [Int: Int] = [:]   // object number -> byte offset in `out`
        var material: EncryptionMaterial?

        init(bytes: [UInt8]) { b = bytes }

        func rewrite(material: EncryptionMaterial?) -> Data? {
            self.material = material
            emit("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n")

            var maxObj = 0
            var trailerDict: [UInt8]? = nil

            while i < b.count {
                skipWhitespaceAndComments()
                if i >= b.count { break }
                if peekKeyword("trailer") {
                    consumeKeyword("trailer")
                    skipWhitespaceAndComments()
                    trailerDict = captureRawDict()   // raw: trailer strings (/ID) stay unencrypted
                    break   // startxref/%%EOF regenerated
                }
                if peekKeyword("xref") { skipToKeyword("trailer"); continue }
                if peekKeyword("startxref") { break }
                guard let (num, gen) = parseObjectHeader() else { return nil }
                maxObj = max(maxObj, num)
                offsets[num] = out.count
                emit("\(num) \(gen) obj\n")
                guard rewriteObjectBody() else { return nil }
                emit("\nendobj\n")
            }
            guard var trailer = trailerDict else { return nil }

            // /Encrypt object goes last.
            var encryptRef = ""
            if let m = material {
                let encNum = maxObj + 1
                maxObj = encNum
                offsets[encNum] = out.count
                emit("\(encNum) 0 obj\n\(m.dictBody)\nendobj\n")
                encryptRef = " /Encrypt \(encNum) 0 R"
            }

            // Rebuild xref + trailer (original /Size replaced, /Encrypt added before >>).
            let xrefStart = out.count
            emit("xref\n0 \(maxObj + 1)\n")
            emit("0000000000 65535 f \n")
            for n in 1...maxObj {
                emit(String(format: "%010d 00000 n \n", offsets[n] ?? 0))
            }
            var t = String(bytes: trailer, encoding: .isoLatin1) ?? ""
            t = t.replacingOccurrences(of: #"/Size \d+"#, with: "/Size \(maxObj + 1)", options: .regularExpression)
            if let r = t.range(of: ">>", options: .backwards) {
                t.replaceSubrange(r, with: "\(encryptRef) >>")
            }
            trailer = [UInt8](t.utf8)
            emit("trailer\n"); out += trailer
            emit("\nstartxref\n\(xrefStart)\n%%EOF\n")
            return Data(out)
        }

        // MARK: low-level

        func emit(_ s: String) { out += [UInt8](s.unicodeScalars.map { UInt8($0.value & 0xFF) }) }
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
        func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

        func skipWhitespaceAndComments() {
            while i < b.count {
                if isWS(b[i]) { i += 1 }
                else if b[i] == UInt8(ascii: "%") { while i < b.count && b[i] != 0x0A && b[i] != 0x0D { i += 1 } }
                else { break }
            }
        }

        func peekKeyword(_ kw: String) -> Bool {
            let k = [UInt8](kw.utf8)
            guard i + k.count <= b.count, Array(b[i..<i+k.count]) == k else { return false }
            let end = i + k.count
            return end >= b.count || isWS(b[end]) || isDelim(b[end])
        }
        func consumeKeyword(_ kw: String) { i += kw.utf8.count }
        func skipToKeyword(_ kw: String) {
            while i < b.count && !peekKeyword(kw) { i += 1 }
        }

        func parseObjectHeader() -> (Int, Int)? {
            guard let num = parseInt() else { return nil }
            skipWhitespaceAndComments()
            guard let gen = parseInt() else { return nil }
            skipWhitespaceAndComments()
            guard peekKeyword("obj") else { return nil }
            consumeKeyword("obj")
            return (num, gen)
        }

        func parseInt() -> Int? {
            skipWhitespaceAndComments()
            var s = ""
            while i < b.count, (b[i] >= 0x30 && b[i] <= 0x39) || b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "+") {
                s.append(Character(UnicodeScalar(b[i]))); i += 1
            }
            return Int(s)
        }

        // One object body: a single value, optionally followed by a stream.
        func rewriteObjectBody() -> Bool {
            skipWhitespaceAndComments()
            var lengthValue: Int? = nil
            guard let value = rewriteValue(captureLength: &lengthValue) else { return false }
            skipWhitespaceAndComments()
            if peekKeyword("stream") {
                consumeKeyword("stream")
                if i < b.count && b[i] == 0x0D { i += 1 }
                if i < b.count && b[i] == 0x0A { i += 1 }
                guard let len = lengthValue, i + len <= b.count else { return false }
                var payload = Array(b[i..<i+len])
                i += len
                skipWhitespaceAndComments()
                guard peekKeyword("endstream") else { return false }
                consumeKeyword("endstream")
                skipWhitespaceAndComments()
                guard peekKeyword("endobj") else { return false }
                consumeKeyword("endobj")
                if let m = material { payload = m.encryptContent(payload) }
                // Patch /Length in the already-rewritten dict.
                var dictText = String(bytes: value, encoding: .isoLatin1) ?? ""
                dictText = dictText.replacingOccurrences(of: #"/Length \d+"#,
                                                         with: "/Length \(payload.count)",
                                                         options: .regularExpression)
                emit(dictText)
                emit("\nstream\n")
                out += payload
                emit("\nendstream")
                return true
            }
            guard peekKeyword("endobj") else { return false }
            consumeKeyword("endobj")
            out += value
            return true
        }

        // Parse+re-serialize one PDF value; literal/hex strings are transformed.
        // captureLength picks up a direct /Length N inside a top-level dict.
        func rewriteValue(captureLength: inout Int?) -> [UInt8]? {
            skipWhitespaceAndComments()
            guard i < b.count else { return nil }
            let c = b[i]
            if c == UInt8(ascii: "<") {
                if i + 1 < b.count && b[i+1] == UInt8(ascii: "<") { return rewriteDict(captureLength: &captureLength) }
                return rewriteHexString()
            }
            if c == UInt8(ascii: "(") { return rewriteLiteralString() }
            if c == UInt8(ascii: "[") {
                i += 1
                var outv: [UInt8] = [UInt8(ascii: "[")]
                while true {
                    skipWhitespaceAndComments()
                    guard i < b.count else { return nil }
                    if b[i] == UInt8(ascii: "]") { i += 1; outv.append(UInt8(ascii: "]")); return outv }
                    var dummy: Int? = nil
                    guard let v = rewriteValue(captureLength: &dummy) else { return nil }
                    outv.append(UInt8(ascii: " ")); outv += v
                }
            }
            if c == UInt8(ascii: "/") {
                var outv: [UInt8] = [c]; i += 1
                while i < b.count && !isWS(b[i]) && !isDelim(b[i]) { outv.append(b[i]); i += 1 }
                return outv
            }
            // number / indirect ref / keyword (true, false, null): copy raw token(s)
            var outv: [UInt8] = []
            while i < b.count && !isWS(b[i]) && !isDelim(b[i]) { outv.append(b[i]); i += 1 }
            guard !outv.isEmpty else { return nil }
            // "N G R" indirect reference: consume the generation and R as part of this value.
            if outv.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                let save = i
                skipWhitespaceAndComments()
                var gen: [UInt8] = []
                while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { gen.append(b[i]); i += 1 }
                if !gen.isEmpty {
                    skipWhitespaceAndComments()
                    if peekKeyword("R") {
                        consumeKeyword("R")
                        return outv + [UInt8(ascii: " ")] + gen + [UInt8](" R".utf8)
                    }
                }
                i = save   // not a reference — plain number
            }
            return outv
        }

        func rewriteDict(captureLength: inout Int?) -> [UInt8]? {
            i += 2
            var outv: [UInt8] = [UInt8](("<<").utf8)
            while true {
                skipWhitespaceAndComments()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ">") && i + 1 < b.count && b[i+1] == UInt8(ascii: ">") {
                    i += 2; outv += [UInt8]((" >>").utf8); return outv
                }
                // key
                guard b[i] == UInt8(ascii: "/") else { return nil }
                var key: [UInt8] = [b[i]]; i += 1
                while i < b.count && !isWS(b[i]) && !isDelim(b[i]) { key.append(b[i]); i += 1 }
                outv.append(UInt8(ascii: " ")); outv += key
                // value
                skipWhitespaceAndComments()
                let keyName = String(bytes: key, encoding: .isoLatin1)
                if keyName == "/Length", let n = peekIntAhead() { captureLength = n }
                var nested: Int? = nil
                guard let v = rewriteValue(captureLength: &nested) else { return nil }
                outv.append(UInt8(ascii: " ")); outv += v
            }
        }

        func peekIntAhead() -> Int? {
            var j = i
            var s = ""
            while j < b.count, b[j] >= 0x30 && b[j] <= 0x39 { s.append(Character(UnicodeScalar(b[j]))); j += 1 }
            // must not be an indirect reference (e.g. "12 0 R")
            var k = j
            while k < b.count && isWS(b[k]) { k += 1 }
            if k < b.count, b[k] >= 0x30 && b[k] <= 0x39 { return Int(s) } // ambiguous — still take first int
            return Int(s)
        }

        func rewriteLiteralString() -> [UInt8]? {
            i += 1
            var plain: [UInt8] = []
            var depth = 1
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { return nil }
                    let e = b[i]
                    switch e {
                    case UInt8(ascii: "n"): plain.append(0x0A); i += 1
                    case UInt8(ascii: "r"): plain.append(0x0D); i += 1
                    case UInt8(ascii: "t"): plain.append(0x09); i += 1
                    case UInt8(ascii: "b"): plain.append(0x08); i += 1
                    case UInt8(ascii: "f"): plain.append(0x0C); i += 1
                    case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"): plain.append(e); i += 1
                    case 0x0A: i += 1                                   // line continuation
                    case 0x0D: i += 1; if i < b.count && b[i] == 0x0A { i += 1 }
                    default:
                        if e >= 0x30 && e <= 0x37 {                     // octal, up to 3 digits
                            var v = 0, n = 0
                            while n < 3, i < b.count, b[i] >= 0x30 && b[i] <= 0x37 {
                                v = v * 8 + Int(b[i] - 0x30); i += 1; n += 1
                            }
                            plain.append(UInt8(v & 0xFF))
                        } else { plain.append(e); i += 1 }
                    }
                    continue
                }
                if c == UInt8(ascii: "(") { depth += 1; plain.append(c); i += 1; continue }
                if c == UInt8(ascii: ")") {
                    depth -= 1
                    if depth == 0 { i += 1; return emitString(plain) }
                    plain.append(c); i += 1; continue
                }
                plain.append(c); i += 1
            }
            return nil
        }

        func rewriteHexString() -> [UInt8]? {
            i += 1
            var hexChars: [UInt8] = []
            while i < b.count, b[i] != UInt8(ascii: ">") {
                if !isWS(b[i]) { hexChars.append(b[i]) }
                i += 1
            }
            guard i < b.count else { return nil }
            i += 1
            if hexChars.count % 2 == 1 { hexChars.append(UInt8(ascii: "0")) }
            var plain: [UInt8] = []
            func nib(_ c: UInt8) -> UInt8? {
                switch c {
                case 0x30...0x39: return c - 0x30
                case 0x41...0x46: return c - 0x41 + 10
                case 0x61...0x66: return c - 0x61 + 10
                default: return nil
                }
            }
            var j = 0
            while j + 1 < hexChars.count {
                guard let h = nib(hexChars[j]), let l = nib(hexChars[j + 1]) else { return nil }
                plain.append(h << 4 | l)
                j += 2
            }
            return emitString(plain)
        }

        // Capture a balanced << >> dict verbatim (string- and nesting-aware), no transform.
        func captureRawDict() -> [UInt8]? {
            guard i + 1 < b.count, b[i] == UInt8(ascii: "<"), b[i+1] == UInt8(ascii: "<") else { return nil }
            let start = i
            var depth = 0
            while i < b.count {
                if b[i] == UInt8(ascii: "<") && i + 1 < b.count && b[i+1] == UInt8(ascii: "<") {
                    depth += 1; i += 2; continue
                }
                if b[i] == UInt8(ascii: ">") && i + 1 < b.count && b[i+1] == UInt8(ascii: ">") {
                    depth -= 1; i += 2
                    if depth == 0 { return Array(b[start..<i]) }
                    continue
                }
                if b[i] == UInt8(ascii: "(") {   // skip literal string safely
                    i += 1
                    var d = 1
                    while i < b.count, d > 0 {
                        if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                        if b[i] == UInt8(ascii: "(") { d += 1 }
                        if b[i] == UInt8(ascii: ")") { d -= 1 }
                        i += 1
                    }
                    continue
                }
                i += 1
            }
            return nil
        }

        // Serialize a (possibly encrypted) string value as a hex string — escaping-proof.
        func emitString(_ plain: [UInt8]) -> [UInt8] {
            let payload = material?.encryptContent(plain) ?? plain
            var outv: [UInt8] = [UInt8(ascii: "<")]
            for byte in payload {
                let hex = String(format: "%02x", byte)
                outv += [UInt8](hex.utf8)
            }
            outv.append(UInt8(ascii: ">"))
            return outv
        }
    }
}

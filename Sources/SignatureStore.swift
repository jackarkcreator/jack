// Persists signatures as transparent PNGs in Application Support so they're reusable across PDFs.
import AppKit

enum SignatureStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jack/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "png" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    @discardableResult
    static func save(_ image: NSImage) -> URL? {
        guard let data = pngData(image) else { return nil }
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        try? data.write(to: url)
        return url
    }

    static func delete(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func image(at url: URL) -> NSImage? { NSImage(contentsOf: url) }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

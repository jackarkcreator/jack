// Jack's Finder extension: a TOP-LEVEL "Convert to PDF with Jack" item in the right-click
// menu (Services/Quick Actions are submenus by Apple's rules; only a Finder Sync extension
// may add a top-level item — the Dropbox pattern).
//
// The extension itself is sandboxed (Apple requires it for every extension point), so it
// never touches the files: it hands the selection to the app over the jack:// URL scheme,
// and the app — unsandboxed — reads and converts. One-time enable per user:
// System Settings → Extensions → Finder.
import Cocoa
import FinderSync

@objc(JackFinderSync)
final class JackFinderSync: FIFinderSync {
    private let convertible: Set<String> = ["docx", "doc", "rtf", "rtfd", "txt"]

    override init() {
        super.init()
        // Watch everywhere — the menu should work wherever the user right-clicks.
        FIFinderSyncController.default().directoryURLs = Set([URL(fileURLWithPath: "/")])
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(),
              items.contains(where: { convertible.contains($0.pathExtension.lowercased()) })
        else { return nil }
        let menu = NSMenu(title: "")
        let mi = NSMenuItem(title: "Convert to PDF with Jack",
                            action: #selector(convertSelection(_:)), keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
        return menu
    }

    @objc private func convertSelection(_ sender: Any?) {
        let items = (FIFinderSyncController.default().selectedItemURLs() ?? [])
            .filter { convertible.contains($0.pathExtension.lowercased()) }
        guard !items.isEmpty else { return }
        var comps = URLComponents()
        comps.scheme = "jack"
        comps.host = "convert"
        // Paths ride as base64 so no character in a filename can break the URL.
        comps.queryItems = items.map {
            URLQueryItem(name: "p", value: Data($0.path.utf8).base64EncodedString())
        }
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}

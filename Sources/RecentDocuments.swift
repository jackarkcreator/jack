// Jack's own recent-documents list. Hand-built (nib-less) menus never get AppKit's
// automatic Open Recent, and the system's recents cap is a user setting that can be
// smaller than we want — so Jack records its own, deterministically.
//
// Recorded in JackDocument.read (every open path: double-click, drag, ⌘O, popover,
// restoration). read() can run off-main (canConcurrentlyReadDocuments) — UserDefaults
// is thread-safe, so recording is too.
import AppKit

enum RecentDocuments {
    private static let key = "jack.recentDocs"
    private static let keep = 15          // stored
    static let shown = 10                 // in the menu

    static func record(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.path
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > keep { list.removeLast(list.count - keep) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// Most-recent-first, pruned to files that still exist.
    static func list() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.count != paths.count { UserDefaults.standard.set(existing, forKey: key) }
        return existing.map { URL(fileURLWithPath: $0) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}

/// Builds and serves the File → Open Recent submenu.
final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = Array(RecentDocuments.list().prefix(RecentDocuments.shown))
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.deletingLastPathComponent().path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if urls.isEmpty {
            let none = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        // The document flow presents its own window (never trust display:true alone).
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                let a = NSAlert()
                a.messageText = "Couldn't open “\(url.lastPathComponent)”"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    @objc private func clearRecents(_ sender: Any?) {
        RecentDocuments.clear()
    }
}

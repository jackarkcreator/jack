// Real main menu for when Jack is fronted as a document app (⌘F, ⌘P, ⌘W, zoom…).
// Document-scoped items use nil targets so the key window's controller answers via the responder chain.
import AppKit

enum MainMenu {
    static func install(newAction: Selector, openAction: Selector, defaultAction: Selector, updateAction: Selector, target: AnyObject) {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Jack", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Check for Updates…", updateAction, "", target: target))
        appMenu.addItem(item("Make Jack the Default PDF App…", defaultAction, "", target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Jack", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Jack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("New PDF", newAction, "n", target: target))
        file.addItem(item("Open…", openAction, "o", target: target))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = RecentMenuDelegate.shared
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: Selector(("saveDocument:")), keyEquivalent: "s")
        file.addItem({ let m = NSMenuItem(title: "Save As…", action: Selector(("saveDocumentAs:")), keyEquivalent: "S")
                       m.keyEquivalentModifierMask = [.command, .shift]; return m }())
        file.addItem(withTitle: "Duplicate", action: Selector(("duplicateDocument:")), keyEquivalent: "")
        file.addItem(withTitle: "Rename…", action: Selector(("renameDocument:")), keyEquivalent: "")
        file.addItem(withTitle: "Move To…", action: Selector(("moveDocument:")), keyEquivalent: "")
        // Versions goes away with autosave-in-place; Revert to Saved is the v2.5 recovery path.
        file.addItem(withTitle: "Revert to Saved", action: Selector(("revertDocumentToSaved:")), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(item("Export Flattened…", #selector(DocumentWindowController.exportFlattened(_:)), "e"))
        file.addItem(item("Clean for Sharing…", #selector(DocumentWindowController.cleanForSharing(_:)), "L"))
        file.addItem(item("Lock for Sharing…", #selector(DocumentWindowController.lockForSharing(_:)), "l"))
        file.addItem(.separator())
        file.addItem(item("Print…", #selector(DocumentWindowController.printDocument(_:)), "p"))
        fileItem.submenu = file
        main.addItem(fileItem)

        // Edit (standard actions so text fields and PDF text selection behave)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(item("Find", #selector(DocumentWindowController.focusSearch(_:)), "f"))
        edit.addItem(item("Find Next", #selector(DocumentWindowController.nextMatch(_:)), "g"))
        edit.addItem(item("Find Previous", #selector(DocumentWindowController.previousMatch(_:)), "G"))
        edit.addItem(.separator())
        edit.addItem(item("Highlight Selection", #selector(DocumentWindowController.highlightSelection(_:)), "H"))
        edit.addItem(item("Underline Selection", #selector(DocumentWindowController.underlineSelection(_:)), "U"))
        edit.addItem(item("Strikethrough Selection", #selector(DocumentWindowController.strikethroughSelection(_:)), "K"))
        edit.addItem(item("Add Comment…", #selector(DocumentWindowController.addComment(_:)), "C"))
        editItem.submenu = edit
        main.addItem(editItem)

        // View
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"))
        view.addItem(item("Actual Size", #selector(DocumentWindowController.actualSize(_:)), "0"))
        view.addItem(item("Zoom to Fit", #selector(DocumentWindowController.zoomToFit(_:)), "9"))
        view.addItem(.separator())
        view.addItem(item("Show/Hide Thumbnails", #selector(DocumentWindowController.toggleSidebar(_:)), "t"))
        view.addItem(.separator())
        view.addItem(item("Continuous Scroll", #selector(DocumentWindowController.displayContinuous(_:)), ""))
        view.addItem(item("Single Page", #selector(DocumentWindowController.displaySinglePage(_:)), ""))
        view.addItem(item("Two Pages", #selector(DocumentWindowController.displayTwoPages(_:)), ""))
        view.addItem(item("Markup", #selector(DocumentWindowController.toggleMarkup(_:)), "A"))
        view.addItem(item("Prepare Form", #selector(DocumentWindowController.toggleForm(_:)), "F"))
        view.addItem(item("Erase", #selector(DocumentWindowController.toggleErase(_:)), ""))
        view.addItem(item("Redact", #selector(DocumentWindowController.toggleRedact(_:)), "R"))
        viewItem.submenu = view
        main.addItem(viewItem)

        // Tools
        let toolsItem = NSMenuItem()
        let tools = NSMenu(title: "Tools")
        tools.addItem(item("Make Searchable (OCR)…", #selector(DocumentWindowController.makeSearchable(_:)), ""))
        tools.addItem(item("Bates Numbering…", #selector(DocumentWindowController.batesNumbering(_:)), ""))
        tools.addItem(item("Watermark…", #selector(DocumentWindowController.addWatermark(_:)), ""))
        tools.addItem(item("Remove Watermark", #selector(DocumentWindowController.removeWatermark(_:)), ""))
        tools.addItem(item("Remove Bates Numbering", #selector(DocumentWindowController.removeBates(_:)), ""))
        tools.addItem(item("Compress…", #selector(DocumentWindowController.compressDocument(_:)), ""))
        tools.addItem(.separator())
        tools.addItem(item("Copy Region as Image", #selector(DocumentWindowController.copyRegionAsImage(_:)), ""))
        tools.addItem(item("Save Region as Image…", #selector(DocumentWindowController.saveRegionAsImage(_:)), ""))
        tools.addItem(.separator())
        tools.addItem(item("Crop Pages…", #selector(DocumentWindowController.cropPages(_:)), ""))
        tools.addItem(item("Remove Crop", #selector(DocumentWindowController.removeCrop(_:)), ""))
        toolsItem.submenu = tools
        main.addItem(toolsItem)

        // Window
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        if key.count == 1, key.rangeOfCharacter(from: .uppercaseLetters) != nil {
            i.keyEquivalentModifierMask = [.command, .shift]
        }
        return i
    }
}

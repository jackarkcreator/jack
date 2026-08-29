// Real main menu for when Jack is fronted as a document app (⌘F, ⌘P, ⌘W, zoom…).
// Document-scoped items use nil targets so the key window's controller answers via the responder chain.
import AppKit

enum MainMenu {
    static func install(openAction: Selector, defaultAction: Selector, updateAction: Selector, target: AnyObject) {
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
        file.addItem(item("Open…", openAction, "o", target: target))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(item("Save PDF…", #selector(DocumentWindowController.saveDocument(_:)), "s"))
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
        view.addItem(item("Markup", #selector(DocumentWindowController.toggleMarkup(_:)), "A"))
        viewItem.submenu = view
        main.addItem(viewItem)

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

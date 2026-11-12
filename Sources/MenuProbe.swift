// Env-gated activation / menu-bar probe (JACK_MENUPROBE=1 → /tmp/jack-menuprobe.log).
// Answers "is Jack really the active app, do menu clicks and key equivalents reach it, and
// does ⇧⌘W find the window's controller" without touching the user's screen.
// JACK_MENUPROBE_AUTO=1 also posts a synthetic ⇧⌘W through NSApp's own event queue once a
// document window is key, and reports whether the Save as Word sheet attached.
import AppKit

enum MenuProbe {
    static let on = ProcessInfo.processInfo.environment["JACK_MENUPROBE"] != nil
    private static var tokens: [Any] = []
    private static var autoDone = false

    static func log(_ s: String) {
        guard on else { return }
        let line = "\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(s)\n"
        let path = "/tmp/jack-menuprobe.log"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    static func state(_ tag: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let key = NSApp.keyWindow.map { "\(type(of: $0)) '\($0.title)' isSheet=\($0.isSheet) sheet=\($0.attachedSheet.map { "\(type(of: $0))" } ?? "none")" } ?? "nil"
        let pol = ["regular", "accessory", "prohibited"][NSApp.activationPolicy().rawValue]
        let target = NSApp.target(forAction: #selector(DocumentWindowController.saveAsWord(_:)), to: nil, from: nil)
        log("[\(tag)] active=\(NSApp.isActive) policy=\(pol) front=\(front) key=\(key) menuItems=\(NSApp.mainMenu?.items.count ?? -1) saveAsWordTarget=\(target.map { "\(type(of: $0))" } ?? "nil")")
    }

    static func install() {
        guard on else { return }
        log("=== probe start pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "?") version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        let nc = NotificationCenter.default
        for (name, tag) in [(NSApplication.didBecomeActiveNotification, "didBecomeActive"),
                            (NSApplication.didResignActiveNotification, "didResignActive"),
                            (NSWindow.didBecomeKeyNotification, "windowDidBecomeKey"),
                            (NSMenu.didBeginTrackingNotification, "menuBeginTracking"),
                            (NSMenu.didSendActionNotification, "menuSentAction")] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                var extra = ""
                if let m = n.object as? NSMenu { extra = " menu='\(m.title)'" }
                if let item = n.userInfo?["MenuItem"] as? NSMenuItem { extra += " item='\(item.title)'" }
                if let w = n.object as? NSWindow { extra = " window=\(type(of: w)) '\(w.title)'" }
                state(tag + extra)
                if tag == "windowDidBecomeKey", (n.object as? NSWindow)?.windowController is DocumentWindowController {
                    runAutoIfWanted()
                }
            })
        }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            log("[workspace] activated \(app?.bundleIdentifier ?? "?")")
        })
        tokens.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { e in
            if e.type == .keyDown {
                log("[event] keyDown chars='\(e.charactersIgnoringModifiers ?? "")' mods=\(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) window=\(e.window.map { "\(type(of: $0))" } ?? "nil")")
            } else {
                log("[event] \(e.type == .leftMouseDown ? "leftMouseDown" : "rightMouseDown") window=\(e.window.map { "\(type(of: $0)) '\($0.title)'" } ?? "nil")")
            }
            return e
        } as Any)
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            n += 1; state("heartbeat \(n)")
            if n >= 60 { t.invalidate() }
        }
    }

    private static func runAutoIfWanted() {
        guard ProcessInfo.processInfo.environment["JACK_MENUPROBE_AUTO"] != nil, !autoDone else { return }
        autoDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            state("auto: before ⇧⌘W")
            if let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu {
                file.update()
                let w = file.item(withTitle: "Export as Word…")
                log("[auto] File ▸ Export as Word… enabled=\(w?.isEnabled ?? false) key=\(w?.keyEquivalent ?? "") mods=\(w?.keyEquivalentModifierMask.rawValue ?? 0)")
            }
            guard let win = NSApp.keyWindow ?? NSApp.mainWindow,
                  let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                            context: nil, characters: "W", charactersIgnoringModifiers: "W",
                                            isARepeat: false, keyCode: 13) else { log("[auto] no window"); return }
            NSApp.postEvent(ev, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                state("auto: after ⇧⌘W")
                log("[auto] RESULT sheet=\(win.attachedSheet.map { "\(type(of: $0))" } ?? "none")")
            }
        }
    }
}

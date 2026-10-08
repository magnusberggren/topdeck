import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        if Updater.finishRename() { return }
        Updater.restoreLoginItemAfterRename()

        Preferences.registerDefaults()
        LoginItem.refresh()
        NSApp.mainMenu = Self.makeMainMenu()

        let controller = IslandController()
        controller.start()
        self.controller = controller

        Updater.shared.canInstallNow = { [weak controller] in controller?.isIdle ?? true }
        Updater.shared.onInstall = { [weak controller] version in controller?.announceUpdate(to: version) }
        Updater.shared.start()

        if !Preferences.hasLaunchedBefore {
            Preferences.hasLaunchedBefore = true
            controller.showWelcomeHint()
        }

        // Turn on Open at Login once, the first time it runs from /Applications.
        if !Preferences.hasSetUpLoginItem, Bundle.main.bundlePath.hasPrefix("/Applications/") {
            Preferences.hasSetUpLoginItem = true
            LoginItem.setEnabled(true)
        }
    }

    /// Never shown, since TopDeck has no menu bar, but its key equivalents
    /// are what make ⌘V, ⌘C, ⌘A and ⌘Z work in the shortcut editor.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit TopDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "TopDeck", action: nil, keyEquivalent: "").submenu = app

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window

        return main
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != mine }
    }
}

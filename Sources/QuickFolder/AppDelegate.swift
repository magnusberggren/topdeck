import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        Preferences.registerDefaults()
        LoginItem.refresh()

        let controller = IslandController()
        controller.start()
        self.controller = controller

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

    private func isAnotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != mine }
    }
}

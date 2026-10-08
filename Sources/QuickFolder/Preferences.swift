import AppKit
import ServiceManagement

enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let showsNewDownloadPreview = "showsNewDownloadPreview"
        static let folderPaths = "folderPaths"
        static let hapticsEnabled = "hapticsEnabled"
        static let showsShortcutsPage = "showsShortcutsPage"
        static let pageOrder = "pageOrder"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let hasSetUpLoginItem = "hasSetUpLoginItem"
        static let showsMeetingsPage = "showsMeetingsPage"
        static let remindsOfMeetings = "remindsOfMeetings"
        static let updatesAutomatically = "updatesAutomatically"
        static let calendarOverrides = "calendarOverrides"
        static let displayID = "displayID"
        static let syncsShortcuts = "syncsShortcuts"
        static let lastShortcutsSync = "lastShortcutsSync"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.showsNewDownloadPreview: true,
            Key.hapticsEnabled: true,
            Key.showsShortcutsPage: true,
            Key.showsMeetingsPage: true,
            Key.remindsOfMeetings: true,
            Key.updatesAutomatically: true,
        ])
    }

    static var showsNewDownloadPreview: Bool {
        get { defaults.bool(forKey: Key.showsNewDownloadPreview) }
        set { defaults.set(newValue, forKey: Key.showsNewDownloadPreview) }
    }

    static var hapticsEnabled: Bool {
        get { defaults.bool(forKey: Key.hapticsEnabled) }
        set { defaults.set(newValue, forKey: Key.hapticsEnabled) }
    }

    static var showsShortcutsPage: Bool {
        get { defaults.bool(forKey: Key.showsShortcutsPage) }
        set { defaults.set(newValue, forKey: Key.showsShortcutsPage) }
    }

    static var showsMeetingsPage: Bool {
        get { defaults.bool(forKey: Key.showsMeetingsPage) }
        set { defaults.set(newValue, forKey: Key.showsMeetingsPage) }
    }

    /// Download and install new releases from GitHub on its own.
    static var updatesAutomatically: Bool {
        get { defaults.bool(forKey: Key.updatesAutomatically) }
        set { defaults.set(newValue, forKey: Key.updatesAutomatically) }
    }

    /// Pop a meeting out of the notch a minute before it starts.
    static var remindsOfMeetings: Bool {
        get { defaults.bool(forKey: Key.remindsOfMeetings) }
        set { defaults.set(newValue, forKey: Key.remindsOfMeetings) }
    }

    /// Calendars the user showed or hid on the Meetings page, by calendar id.
    /// The rest follow the default: your own calendars on, shared ones off.
    static var calendarOverrides: [String: Bool] {
        get { defaults.dictionary(forKey: Key.calendarOverrides) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: Key.calendarOverrides) }
    }

    /// The display the island lives on, by its UUID. nil picks the built-in
    /// display with a notch, or the main display if none has one.
    static var displayID: String? {
        get { defaults.string(forKey: Key.displayID) }
        set { defaults.set(newValue, forKey: Key.displayID) }
    }

    static var syncsShortcuts: Bool {
        get { defaults.bool(forKey: Key.syncsShortcuts) }
        set { defaults.set(newValue, forKey: Key.syncsShortcuts) }
    }

    /// When this Mac last wrote or read the shared shortcuts file.
    static var lastShortcutsSync: Date? {
        get { defaults.object(forKey: Key.lastShortcutsSync) as? Date }
        set { defaults.set(newValue, forKey: Key.lastShortcutsSync) }
    }

    /// Page ids (folder paths and "shortcuts") from top to bottom, as the user
    /// arranged them. Pages missing from it keep their natural place at the end.
    static var pageOrder: [String] {
        get { defaults.stringArray(forKey: Key.pageOrder) ?? [] }
        set { defaults.set(newValue, forKey: Key.pageOrder) }
    }

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    static var hasSetUpLoginItem: Bool {
        get { defaults.bool(forKey: Key.hasSetUpLoginItem) }
        set { defaults.set(newValue, forKey: Key.hasSetUpLoginItem) }
    }

    /// The folders the island pages through, in order. Downloads and Desktop by default.
    static var folders: [URL] {
        get {
            guard let paths = defaults.stringArray(forKey: Key.folderPaths), !paths.isEmpty else {
                return [downloadsFolder, desktopFolder]
            }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set { defaults.set(newValue.map(\.path), forKey: Key.folderPaths) }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    static var desktopFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }
}

enum Haptics {
    /// Force Touch trackpads only play these while a finger is on the trackpad.
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Preferences.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

enum LoginItem {
    /// Asking ServiceManagement takes ~0.4s, far too slow for opening a menu,
    /// so the answer is cached and refreshed in the background.
    private(set) static var isEnabled = false
    private static let queue = DispatchQueue(label: "QuickFolder.LoginItem")

    static func refresh() {
        queue.async {
            let enabled = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async { isEnabled = enabled }
        }
    }

    static func setEnabled(_ enabled: Bool) {
        // Registering only makes sense for a real .app bundle, not `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        isEnabled = enabled
        queue.async {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("QuickFolder: could not update login item: \(error.localizedDescription)")
            }
            refresh()
        }
    }
}

import AppKit
import Security
import ServiceManagement

/// Keeps TopDeck up to date from the repo's GitHub Releases.
///
/// Each release is tagged `v1.<build>` and carries `TopDeck.zip`. A newer
/// build is downloaded, checked to be signed by the same developer as this
/// copy, swapped in place of the running app, and relaunched.
final class Updater {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case installing(version: String)
        case failed
    }

    static let shared = Updater()

    /// Called on the main thread when an update is about to replace the app,
    /// so the island can say so first.
    var onInstall: ((String) -> Void)?
    /// Asked before installing; the update waits while this returns false
    /// (the island is open, or a call is about to start).
    var canInstallNow: (() -> Bool)?

    private(set) var status: Status = .idle
    private var timer: Timer?
    private var pending: (version: String, app: URL)?

    private static let repo = "magnusberggren/topdeck"
    private static let assetName = "TopDeck.zip"
    private static let interval: TimeInterval = 6 * 3600
    /// Only apps from this developer team are accepted as updates.
    private static let teamID = "AURJLA4GTL"

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func start() {
        // Updating only makes sense for an installed .app, not `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app", Preferences.updatesAutomatically else { return }
        var delay: TimeInterval = 20
        #if DEBUG
        if ProcessInfo.processInfo.environment["QF_DEBUG_RELEASE"] != nil { delay = 3 }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 600
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check(completion: ((Status) -> Void)? = nil) {
        if let pending {
            installWhenIdle(pending.version, app: pending.app)
            completion?(.installing(version: pending.version))
            return
        }
        guard status != .checking else { return }
        status = .checking

        var latest = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        #if DEBUG
        // QF_DEBUG_RELEASE=<url of a release JSON> tries an update from anywhere, file:// included.
        if let override = ProcessInfo.processInfo.environment["QF_DEBUG_RELEASE"].flatMap(URL.init(string:)) {
            latest = override
        }
        #endif
        var request = URLRequest(url: latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let release = try? JSONDecoder().decode(Release.self, from: data),
                  let build = release.build,
                  let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
                self.finish(.failed, completion)
                return
            }
            guard build > Self.currentBuild else {
                self.finish(.upToDate, completion)
                return
            }
            self.download(asset.browserDownloadURL, version: release.version, completion: completion)
        }.resume()
    }

    private func finish(_ status: Status, _ completion: ((Status) -> Void)?) {
        DispatchQueue.main.async {
            self.status = status == .checking ? .idle : status
            completion?(status)
        }
    }

    // MARK: - Download

    private func download(_ url: URL, version: String, completion: ((Status) -> Void)?) {
        URLSession.shared.downloadTask(with: url) { [weak self] file, _, _ in
            guard let self else { return }
            guard let file, let app = Self.unpack(file) else {
                self.finish(.failed, completion)
                return
            }
            DispatchQueue.main.async {
                self.pending = (version, app)
                self.status = .installing(version: version)
                completion?(.installing(version: version))
                self.installWhenIdle(version, app: app)
            }
        }.resume()
    }

    /// Unzips next to nothing else, in a fresh temporary folder, and checks
    /// the signature before anything is trusted.
    private static func unpack(_ zip: URL) -> URL? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("TopDeck-update-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let app = folder.appendingPathComponent("TopDeck.app", isDirectory: true)
        return isTrusted(app) ? app : nil
    }

    /// Same bundle id, signed with a Developer ID or Apple Development
    /// certificate from our team, and intact.
    private static func isTrusted(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let id = Bundle.main.bundleIdentifier ?? "no.shuuto.QuickFolder"
        let text = "identifier \"\(id)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // MARK: - Install

    private func installWhenIdle(_ version: String, app: URL) {
        guard canInstallNow?() ?? true else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.installWhenIdle(version, app: app)
            }
            return
        }
        onInstall?(version)
        // Let the island say so before it goes away for a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.install(app)
        }
    }

    private func install(_ app: URL) {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        do {
            _ = try fm.replaceItemAt(target, withItemAt: app, backupItemName: nil, options: [])
        } catch {
            NSLog("TopDeck: update failed: \(error.localizedDescription)")
            pending = nil
            status = .failed
            return
        }
        Self.relaunch(at: target)
    }

    /// Opens `app` from a fresh process once this one has quit.
    static func relaunch(at app: URL) {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: - Rename

    /// The app was called QuickFolder before it became TopDeck. Copies from
    /// then update into /Applications/QuickFolder.app; this renames that to
    /// TopDeck.app and starts again from there, keeping Open at Login.
    /// Returns true when the app is about to restart.
    static func finishRename() -> Bool {
        let current = Bundle.main.bundleURL
        guard current.lastPathComponent == "QuickFolder.app" else { return false }
        let target = current.deletingLastPathComponent().appendingPathComponent("TopDeck.app", isDirectory: true)
        let fm = FileManager.default
        let wasLoginItem = SMAppService.mainApp.status == .enabled
        do {
            // The copy that's running is the one that just updated, so it wins.
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            if wasLoginItem { try? SMAppService.mainApp.unregister() }
            try fm.moveItem(at: current, to: target)
        } catch {
            NSLog("TopDeck: couldn’t rename QuickFolder.app: \(error.localizedDescription)")
            if wasLoginItem { try? SMAppService.mainApp.register() }
            return false
        }
        UserDefaults.standard.set(wasLoginItem, forKey: Self.reregisterKey)
        relaunch(at: target)
        return true
    }

    /// After the rename, Open at Login has to point at the new name.
    static func restoreLoginItemAfterRename() {
        guard UserDefaults.standard.object(forKey: reregisterKey) != nil else { return }
        if UserDefaults.standard.bool(forKey: reregisterKey) { LoginItem.setEnabled(true) }
        UserDefaults.standard.removeObject(forKey: reregisterKey)
    }

    private static let reregisterKey = "reregisterLoginItemAfterRename"

    // MARK: - GitHub

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }

        /// "v1.42" → "1.42".
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        /// "v1.42" → 42.
        var build: Int? { version.split(separator: ".").last.flatMap { Int($0) } }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

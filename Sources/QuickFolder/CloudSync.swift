import Foundation

/// The Shortcuts deck as a file, for syncing through iCloud Drive and for
/// sharing with someone else.
struct DeckFile: Codable {
    var version = 1
    var updated: Date
    var keys: [DeckKey]

    static func decode(_ data: Data) -> DeckFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(DeckFile.self, from: data) { return file }
        // A bare list of keys is fine too.
        return (try? decoder.decode([DeckKey].self, from: data)).map { DeckFile(updated: .distantPast, keys: $0) }
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

/// Settings as a file, so every Mac on the same Apple ID is set up alike.
struct SettingsFile: Codable {
    var version = 1
    var updated: Date
    var settings: SyncedSettings

    static func decode(_ data: Data) -> SettingsFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SettingsFile.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

enum CloudSync {
    static var iCloudDrive: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// iCloud Drive is on, so there's somewhere to sync to.
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDrive.path)
    }

    static var folder: URL { iCloudDrive.appendingPathComponent("QuickFolder", isDirectory: true) }
}

/// One JSON file in iCloud Drive/QuickFolder, shared by every Mac signed in to
/// the same Apple ID. The newest change wins. Callbacks arrive on the main
/// thread.
final class CloudFile<Content: Equatable> {
    var onRemoteChange: ((Content) -> Void)?

    private let url: URL
    private let lastSyncKey: String
    private let encode: (Content, Date) -> Data?
    private let decode: (Data) -> (updated: Date, content: Content)?

    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?
    /// What's in the file as far as this Mac knows, to skip echoes of its own writes.
    private var lastContent: Content?

    init(
        name: String,
        lastSyncKey: String,
        encode: @escaping (Content, Date) -> Data?,
        decode: @escaping (Data) -> (updated: Date, content: Content)?
    ) {
        url = CloudSync.folder.appendingPathComponent(name)
        self.lastSyncKey = lastSyncKey
        self.encode = encode
        self.decode = decode
        queue = DispatchQueue(label: "QuickFolder.CloudFile.\(name)", qos: .utility)
    }

    /// When this Mac last wrote or read the file. nil until it first joins.
    private var lastSync: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncKey) }
    }

    /// Joins the shared file. `merge` decides what this Mac ends up with
    /// when it joins for the first time and the file already exists; after
    /// that, the newer side wins.
    func start(local: Content, merge: @escaping (_ remote: Content, _ local: Content) -> Content) {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: CloudSync.folder, withIntermediateDirectories: true)
            let remote = read()

            var content = local
            if let remote {
                if let lastSync {
                    if remote.updated > lastSync { content = remote.content }
                } else {
                    content = merge(remote.content, local)
                }
            }

            if content != remote?.content {
                write(content)
            } else {
                lastContent = content
                lastSync = remote?.updated ?? Date()
            }
            if content != local {
                DispatchQueue.main.async { self.onRemoteChange?(content) }
            }
            watch()
        }
    }

    /// Leaves the file. Joining again later counts as joining for the first time.
    func stop() {
        queue.async { [self] in
            pendingCheck?.cancel()
            source?.cancel()
            source = nil
            lastContent = nil
            lastSync = nil
        }
    }

    func save(_ content: Content) {
        queue.async { [self] in
            guard content != lastContent else { return }
            write(content)
        }
    }

    /// Looks for changes from other Macs now, for when the folder watcher
    /// missed them (iCloud sometimes swaps whole folders around).
    func check() {
        queue.async { [self] in
            guard lastContent != nil else { return }
            if source == nil { watch() }
            guard let remote = read(), remote.content != lastContent else { return }
            if let lastSync, remote.updated <= lastSync { return }
            lastContent = remote.content
            lastSync = remote.updated
            DispatchQueue.main.async { self.onRemoteChange?(remote.content) }
        }
    }

    // MARK: - File

    private func read() -> (updated: Date, content: Content)? {
        var data: Data?
        var error: NSError?
        // Coordinated, so a file iCloud has offloaded is downloaded first.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data.flatMap(decode)
    }

    private func write(_ content: Content) {
        let now = Date()
        guard let data = encode(content, now) else { return }
        try? FileManager.default.createDirectory(at: CloudSync.folder, withIntermediateDirectories: true)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            if (try? data.write(to: url, options: .atomic)) != nil {
                lastContent = content
                lastSync = now
            }
        }
    }

    private func watch() {
        guard source == nil else { return }
        let fd = open(CloudSync.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                self.source = nil
            }
            self.pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.check() }
            self.pendingCheck = work
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}

extension CloudFile where Content == [DeckKey] {
    static func shortcuts() -> CloudFile<[DeckKey]> {
        CloudFile(
            name: "Shortcuts.json",
            lastSyncKey: "lastShortcutsSync",
            encode: { keys, date in DeckFile(updated: date, keys: keys).encoded() },
            decode: { data in DeckFile.decode(data).map { ($0.updated, $0.keys) } }
        )
    }
}

extension CloudFile where Content == SyncedSettings {
    static func settings() -> CloudFile<SyncedSettings> {
        CloudFile(
            name: "Settings.json",
            lastSyncKey: "lastSettingsSync",
            encode: { settings, date in SettingsFile(updated: date, settings: settings).encoded() },
            decode: { data in SettingsFile.decode(data).map { ($0.updated, $0.settings) } }
        )
    }
}

extension Array where Element == DeckKey {
    /// A key that does the same thing, whatever its id. Keeps the starter keys
    /// from doubling up when two Macs first meet.
    func contains(sameAs key: DeckKey) -> Bool {
        contains { $0.title == key.title && $0.action == key.action }
    }
}

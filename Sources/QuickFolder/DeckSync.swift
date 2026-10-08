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

/// Keeps the deck the same on every Mac signed in to the same Apple ID, via
/// a file in iCloud Drive. The newest change wins. Callbacks arrive on the
/// main thread.
final class DeckSync {
    var onRemoteChange: (([DeckKey]) -> Void)?

    private let queue = DispatchQueue(label: "QuickFolder.DeckSync", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pendingCheck: DispatchWorkItem?
    /// What's in the file as far as this Mac knows, to skip echoes of its own writes.
    private var lastKeys: [DeckKey]?

    static var iCloudDrive: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDrive.path)
    }

    static var folder: URL { iCloudDrive.appendingPathComponent("QuickFolder", isDirectory: true) }
    static var file: URL { folder.appendingPathComponent("Shortcuts.json") }

    /// Joins the shared file. The first time on this Mac, keys made here are
    /// added to the ones already in iCloud; after that the newer side wins.
    func start(local: [DeckKey], hasLocalKeys: Bool) {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let remote = read()
            let lastSync = Preferences.lastShortcutsSync

            var keys = local
            if let remote {
                if lastSync == nil {
                    let remoteIDs = Set(remote.keys.map(\.id))
                    keys = hasLocalKeys
                        ? remote.keys + local.filter { !remoteIDs.contains($0.id) && !remote.keys.contains(sameAs: $0) }
                        : remote.keys
                } else if remote.updated > lastSync! {
                    keys = remote.keys
                }
            }

            if keys != remote?.keys {
                write(keys)
            } else {
                lastKeys = keys
                Preferences.lastShortcutsSync = remote?.updated ?? Date()
            }
            if keys != local {
                DispatchQueue.main.async { self.onRemoteChange?(keys) }
            }
            watch()
        }
    }

    func stop() {
        queue.async { [self] in
            pendingCheck?.cancel()
            source?.cancel()
            source = nil
            lastKeys = nil
        }
    }

    func save(_ keys: [DeckKey]) {
        queue.async { [self] in write(keys) }
    }

    /// Looks for changes from other Macs now, for when the folder watcher
    /// missed them (iCloud sometimes swaps whole folders around).
    func check() {
        queue.async { [self] in
            guard source != nil || lastKeys != nil else { return }
            if source == nil { watch() }
            guard let remote = read(), remote.keys != lastKeys else { return }
            if let lastSync = Preferences.lastShortcutsSync, remote.updated <= lastSync { return }
            lastKeys = remote.keys
            Preferences.lastShortcutsSync = remote.updated
            DispatchQueue.main.async { self.onRemoteChange?(remote.keys) }
        }
    }

    // MARK: - File

    private func read() -> DeckFile? {
        var data: Data?
        var error: NSError?
        // Coordinated, so a file iCloud has offloaded is downloaded first.
        NSFileCoordinator().coordinate(readingItemAt: Self.file, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data.flatMap(DeckFile.decode)
    }

    private func write(_ keys: [DeckKey]) {
        let now = Date()
        guard let data = DeckFile(updated: now, keys: keys).encoded() else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: Self.file, options: .forReplacing, error: &error) { url in
            if (try? data.write(to: url, options: .atomic)) != nil {
                lastKeys = keys
                Preferences.lastShortcutsSync = now
            }
        }
    }

    private func watch() {
        guard source == nil else { return }
        let fd = open(Self.folder.path, O_EVTONLY)
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

extension Array where Element == DeckKey {
    /// A key that does the same thing, whatever its id. Keeps the starter keys
    /// from doubling up when two Macs first meet.
    func contains(sameAs key: DeckKey) -> Bool {
        contains { $0.title == key.title && $0.action == key.action }
    }
}

import Foundation

struct DownloadItem: Identifiable, Equatable {
    let url: URL
    let dateAdded: Date
    let modified: Date
    let size: Int64?
    let isFolder: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// Changes whenever the file's contents change, so thumbnails refresh.
    var thumbnailKey: String { "\(url.path)|\(modified.timeIntervalSinceReferenceDate)" }

    static let resourceKeys: Set<URLResourceKey> = [
        .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
        .totalFileSizeKey, .fileSizeKey, .isDirectoryKey, .isPackageKey,
    ]

    /// Reads one file's dates and size. Fast when the URL came from a
    /// directory listing that prefetched `resourceKeys`.
    init(url: URL) {
        let values = try? url.resourceValues(forKeys: Self.resourceKeys)
        let modified = values?.contentModificationDate ?? .distantPast
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let size = (values?.totalFileSize ?? values?.fileSize).map(Int64.init)
        self.url = url
        self.modified = modified
        self.dateAdded = values?.addedToDirectoryDate ?? values?.creationDate ?? modified
        self.isFolder = isDirectory && !isPackage
        self.size = isDirectory && !isPackage ? nil : size
    }
}

enum FolderAccess: Equatable {
    case ok
    case denied
    case missing
}

/// Everything one look at a folder turns up.
struct FolderScan {
    var items: [DownloadItem] = []
    var access: FolderAccess = .ok
    /// Downloads still being written, by their finished file name.
    var partials: [String] = []
    var cleanup: Cleanup?
}

/// Watches a folder and reports its most recently added files.
final class DownloadsMonitor {
    var onChange: ((FolderScan) -> Void)?
    var onNewDownload: ((DownloadItem) -> Void)?

    private(set) var folder: URL
    private let queue = DispatchQueue(label: "TopDeck.DownloadsMonitor", qos: .userInitiated)
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?
    private var known: Set<String>?

    private static let maxItems = 40
    private static let freshness: TimeInterval = 120

    /// A partial file untouched this long is an abandoned download, not a live one.
    private static let partialTimeout: TimeInterval = 20
    /// Installers older than this are offered for cleanup.
    private static let cleanupAge: TimeInterval = 7 * 86_400
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    /// Extensions browsers use while a download is still in flight.
    static let partialExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "opdownload", "tmp", "!ut", "aria2",
    ]

    init(folder: URL) {
        self.folder = folder
    }

    func start(folder: URL? = nil) {
        queue.async { [self] in
            stopWatching()
            if let folder { self.folder = folder }
            known = nil
            scan()
        }
    }

    func stop() {
        onChange = nil
        onNewDownload = nil
        queue.async { [self] in
            pendingScan?.cancel()
            stopWatching()
        }
    }

    /// Where a file being downloaded will end up: "a.pdf.crdownload" and
    /// "a.pdf.download/a.pdf" both mean "a.pdf" in the same folder.
    static func finalLocation(of url: URL) -> (folder: URL, name: String) {
        var url = url
        if url.deletingLastPathComponent().pathExtension.lowercased() == "download" {
            url = url.deletingLastPathComponent()
        }
        let folder = url.deletingLastPathComponent()
        let name = partialExtensions.contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
        return (folder, name)
    }

    /// Re-reads the folder now. Used when the island opens after access was denied.
    func refresh() {
        queue.async { [self] in scan() }
    }

    // MARK: - Watching

    private func startWatchingIfNeeded() {
        guard source == nil else { return }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .link],
            queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // The folder itself moved or vanished; reattach to the path.
                self.stopWatching()
            }
            self.scheduleScan(after: 0.2)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    private func scheduleScan(after delay: TimeInterval) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Scanning

    private func scan() {
        let keys = DownloadItem.resourceKeys

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            let code = (error as NSError).code
            let access: FolderAccess = (code == NSFileReadNoPermissionError) ? .denied : .missing
            if access == .missing { stopWatching() }
            DispatchQueue.main.async { self.onChange?(FolderScan(access: access)) }
            return
        }

        startWatchingIfNeeded()

        let now = Date()
        let names = Set(urls.map(\.lastPathComponent))
        var items: [DownloadItem] = []
        var partials: [String] = []
        var installers: [DownloadItem] = []
        items.reserveCapacity(urls.count)

        for url in urls {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if Self.partialExtensions.contains(ext) {
                if Self.isBeingWritten(url, now: now) {
                    partials.append(Self.finalLocation(of: url).name)
                }
                continue
            }
            // Firefox keeps an empty placeholder next to its .part file until it finishes.
            if Self.partialExtensions.contains(where: { names.contains("\(name).\($0)") }) { continue }

            let item = DownloadItem(url: url)
            items.append(item)
            if Self.installerExtensions.contains(ext), now.timeIntervalSince(item.dateAdded) > Self.cleanupAge {
                installers.append(item)
            }
        }

        items.sort { $0.dateAdded > $1.dateAdded }
        if items.count > Self.maxItems { items.removeSubrange(Self.maxItems...) }

        var newest: DownloadItem?
        if var known {
            newest = items.first { item in
                !known.contains(item.id)
                    && now.timeIntervalSince(max(item.dateAdded, item.modified)) < Self.freshness
            }
            known.formUnion(items.map(\.id))
            self.known = known
        } else {
            known = Set(items.map(\.id))
        }

        let cleanup = installers.isEmpty ? nil : Cleanup(
            files: installers.map(\.url),
            bytes: installers.reduce(0) { $0 + ($1.size ?? 0) }
        )

        // Growing files don't touch the folder, so poll while downloads run.
        if !partials.isEmpty { scheduleScan(after: 2) }

        let result = FolderScan(items: items, access: .ok, partials: partials, cleanup: cleanup)
        DispatchQueue.main.async {
            self.onChange?(result)
            if let newest { self.onNewDownload?(newest) }
        }
    }

    /// Safari's .download is a folder whose own date doesn't change as the
    /// data inside grows, so look one level in.
    private static func isBeingWritten(_ url: URL, now: Date) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        var latest = values.contentModificationDate ?? .distantPast
        if values.isDirectory == true,
           let inner = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for child in inner {
                if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    latest = max(latest, date)
                }
            }
        }
        return now.timeIntervalSince(latest) < partialTimeout
    }
}

import Foundation

/// A download some app is reporting progress for.
struct ReportedDownload: Equatable {
    /// Folder the finished file will land in.
    var folderPath: String
    /// The finished file's name, without .crdownload, .download or .part.
    var name: String
    var fraction: Double?
}

/// Browsers publish an `NSProgress` for every file they download; Finder uses
/// it to draw the bar on the file's icon. This listens for those in the
/// watched folders. State is only touched on the main thread; the system's
/// callbacks hop there first.
final class DownloadProgressWatcher: @unchecked Sendable {
    var onChange: (([ReportedDownload]) -> Void)?

    private var subscriptions: [String: Any] = [:]
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var flushScheduled = false

    private struct Tracked {
        let progress: Progress
        let observations: [NSKeyValueObservation]
    }

    func watch(_ folders: [URL]) {
        let paths = Set(folders.map(\.path))
        for (path, token) in subscriptions where !paths.contains(path) {
            Progress.removeSubscriber(token)
            subscriptions[path] = nil
        }
        for folder in folders where subscriptions[folder.path] == nil {
            subscriptions[folder.path] = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
                DispatchQueue.main.async { self?.add(progress) }
                return { DispatchQueue.main.async { self?.remove(progress) } }
            }
        }
    }

    private func add(_ progress: Progress) {
        let changed: (Progress, NSKeyValueObservedChange<Double>) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleFlush() }
        }
        let observations = [
            progress.observe(\.fractionCompleted, changeHandler: changed),
        ]
        tracked[ObjectIdentifier(progress)] = Tracked(progress: progress, observations: observations)
        scheduleFlush()
    }

    private func remove(_ progress: Progress) {
        tracked[ObjectIdentifier(progress)] = nil
        scheduleFlush()
    }

    /// Progress can tick hundreds of times a second; the UI needs ~10.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.onChange?(self.tracked.values.compactMap { Self.report(for: $0.progress) })
        }
    }

    private static func report(for progress: Progress) -> ReportedDownload? {
        guard let url = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL,
              !progress.isFinished, !progress.isCancelled else { return nil }
        let (folder, name) = DownloadsMonitor.finalLocation(of: url)
        let fraction = progress.isIndeterminate || progress.totalUnitCount <= 0 ? nil : progress.fractionCompleted
        return ReportedDownload(folderPath: folder.path, name: name, fraction: fraction.map { min(max($0, 0), 1) })
    }
}

import AppKit
import Quartz

enum FileActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    static func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            playTrashSound()
        } catch {
            NSSound.beep()
        }
    }

    static func playTrashSound() {
        trashSound?.stop()
        trashSound?.play()
    }

    /// Apps that can open `url`, default first, like Finder's "Open With".
    static func applications(toOpen url: URL) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard let preferred = NSWorkspace.shared.urlForApplication(toOpen: url) else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    private static let trashSound: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true
    )
}

/// Shows the system Quick Look panel for a single file.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }

    func windowWillClose(_ notification: Notification) {
        // Hand focus back to whatever the user was doing.
        DispatchQueue.main.async { NSApp.deactivate() }
    }
}

/// Opens a folder in Finder's column view, sorted newest first.
///
/// Finder can switch views over AppleScript, but its column-view sort order
/// isn't scriptable and is one setting shared by every folder. So after the
/// window is up, this presses Finder's own View › Sort By › Date Added
/// shortcut (⌃⌥⌘4), which needs Accessibility permission.
enum FinderWindow {
    static func openNewestFirst(_ folder: URL) {
        let path = folder.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // `open` brings an existing window for the folder forward instead of
        // making a new one each time.
        let script = """
        tell application "Finder"
            activate
            open (POSIX file "\(path)" as alias)
            set current view of front Finder window to column view
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            DispatchQueue.main.async {
                guard process.terminationStatus == 0 else {
                    // Automation was denied or Finder misbehaved; still open the folder.
                    NSWorkspace.shared.open(folder)
                    return
                }
                sortByDateAdded()
            }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(folder)
        }
    }

    private static func sortByDateAdded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return }

        let key: CGKeyCode = 21 // the "4" key
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.postToPid(finder.processIdentifier)
        }
    }
}

/// Unpacks archives next to themselves, then moves the archive to the Trash.
enum Archive {
    private static let extensions: Set<String> = ["zip", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz"]

    static func canExtract(_ item: DownloadItem) -> Bool {
        guard !item.isFolder else { return false }
        let ext = item.url.pathExtension.lowercased()
        // Bare .gz/.bz2/.xz are only archives when they wrap a tar.
        if ["gz", "bz2", "xz"].contains(ext) {
            return item.url.deletingPathExtension().pathExtension.lowercased() == "tar"
        }
        return extensions.contains(ext)
    }

    enum Failure: Error { case couldNotExtract, empty }

    /// Like Archive Utility: a single top-level item lands in the folder as is,
    /// several items go into a folder named after the archive. Never overwrites.
    static func extractAndTrash(_ archive: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try extract(archive) }
            if case .success = result {
                try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func extract(_ archive: URL) throws -> URL {
        let fm = FileManager.default
        let folder = archive.deletingLastPathComponent()
        // Hidden, so the folder watcher never sees half-extracted files.
        let staging = folder.appendingPathComponent(".quickfolder-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let process = Process()
        if archive.pathExtension.lowercased() == "zip" {
            // ditto keeps macOS metadata the way Archive Utility does.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, staging.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archive.path, "-C", staging.path]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.couldNotExtract }

        let contents = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard !contents.isEmpty else { throw Failure.empty }

        if contents.count == 1 {
            let destination = uniqueURL(for: contents[0].lastPathComponent, in: folder)
            try fm.moveItem(at: contents[0], to: destination)
            return destination
        }

        let destination = uniqueURL(for: baseName(of: archive), in: folder)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        for item in contents {
            try fm.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
        return destination
    }

    /// "Report.tar.gz" → "Report".
    private static func baseName(of archive: URL) -> String {
        var url = archive.deletingPathExtension()
        if url.pathExtension.lowercased() == "tar" { url = url.deletingPathExtension() }
        return url.lastPathComponent
    }

    /// "Report" → "Report 2" → "Report 3", like Finder.
    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

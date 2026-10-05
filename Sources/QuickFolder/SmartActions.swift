import AppKit

/// A one-click action offered on a tile, depending on the file type.
enum SmartAction: Equatable {
    case extract
    case install

    static func available(for item: DownloadItem) -> SmartAction? {
        if Archive.canExtract(item) { return .extract }
        if !item.isFolder && item.url.pathExtension.lowercased() == "dmg" { return .install }
        return nil
    }

    var symbol: String {
        switch self {
        case .extract: "archivebox.fill"
        case .install: "arrow.down.app.fill"
        }
    }

    var hoverLabel: String {
        switch self {
        case .extract: "Extract & Trash"
        case .install: "Install App"
        }
    }

    var busyLabel: String {
        switch self {
        case .extract: "Extracting…"
        case .install: "Installing…"
        }
    }

    var menuTitle: String {
        switch self {
        case .extract: "Extract & Move Archive to Trash"
        case .install: "Install & Move Disk Image to Trash"
        }
    }
}

/// Installs the app inside a disk image the way you would by hand: mount it,
/// copy the app to /Applications, eject, and move the image to the Trash.
enum DiskImageInstaller {
    enum Outcome {
        case installed(URL)
        /// Not a plain drag-to-Applications image (a license to accept, an
        /// installer package, no app). Opened in Finder or Installer instead.
        case handedOff
    }

    enum Failure: Error {
        case appRunning(String)
        /// macOS blocks replacing other developers' apps until QuickFolder
        /// has App Management permission.
        case needsAppManagement
        case failed
    }

    static func install(_ image: URL, completion: @escaping (Result<Outcome, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(image)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(_ image: URL) -> Result<Outcome, Failure> {
        let fm = FileManager.default
        guard let mount = attach(image) else {
            // Images with a license agreement can't be mounted silently.
            DispatchQueue.main.async { NSWorkspace.shared.open(image) }
            return .success(.handedOff)
        }

        let contents = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let apps = contents.filter { $0.pathExtension.lowercased() == "app" }
        guard let app = apps.first(where: { !$0.lastPathComponent.localizedCaseInsensitiveContains("uninstall") }) ?? apps.first else {
            let package = contents.first { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
            DispatchQueue.main.async { NSWorkspace.shared.open(package ?? mount) }
            return .success(.handedOff)
        }

        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(app.lastPathComponent)
        let name = (app.lastPathComponent as NSString).deletingPathExtension

        if fm.fileExists(atPath: destination.path) {
            let isRunning = DispatchQueue.main.sync {
                NSWorkspace.shared.runningApplications.contains {
                    $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
                }
            }
            if isRunning {
                detach(mount)
                return .failure(.appRunning(name))
            }
            // The old version goes to the Trash, so this can be undone.
            do {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            } catch {
                detach(mount)
                let code = (error as NSError).code
                let denied = code == NSFileWriteNoPermissionError || code == NSFileReadNoPermissionError
                return .failure(denied ? .needsAppManagement : .failed)
            }
        }

        let copied = runTool("/usr/bin/ditto", [app.path, destination.path])
        detach(mount)
        guard copied else { return .failure(.failed) }

        try? fm.trashItem(at: image, resultingItemURL: nil)
        return .success(.installed(destination))
    }

    private static func attach(_ image: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-noautoopen", "-plist", image.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // No input, so a license prompt fails instead of hanging.
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else { return nil }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    private static func detach(_ mount: URL) {
        if !runTool("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) {
            _ = runTool("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
        }
    }

    @discardableResult
    private static func runTool(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

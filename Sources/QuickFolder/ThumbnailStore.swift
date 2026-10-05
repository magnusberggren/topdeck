import AppKit
import Observation
import QuickLookThumbnailing

struct Thumbnail {
    let image: NSImage
    /// True for a Finder icon, false for a real preview of the contents.
    let isIcon: Bool
}

@Observable
final class ThumbnailStore {
    private(set) var thumbnails: [String: Thumbnail] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    static let pointSize = CGSize(width: 56, height: 56)

    func thumbnail(for item: DownloadItem) -> Thumbnail? {
        thumbnails[item.thumbnailKey]
    }

    /// Loads previews for `items` and forgets everything else.
    func sync(with items: [DownloadItem]) {
        let wanted = Set(items.map(\.thumbnailKey))
        if thumbnails.keys.contains(where: { !wanted.contains($0) }) {
            thumbnails = thumbnails.filter { wanted.contains($0.key) }
        }

        for item in items {
            let key = item.thumbnailKey
            guard thumbnails[key] == nil, !inFlight.contains(key) else { continue }
            inFlight.insert(key)

            // The Finder icon is instant; the real preview fades in over it.
            thumbnails[key] = Thumbnail(image: NSWorkspace.shared.icon(forFile: item.url.path), isIcon: true)

            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url,
                size: Self.pointSize,
                scale: scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(key)
                    guard let representation, wanted.contains(key), self.thumbnails[key] != nil else { return }
                    self.thumbnails[key] = Thumbnail(image: representation.nsImage, isIcon: false)
                }
            }
        }
    }
}

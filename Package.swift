// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TopDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TopDeck",
            path: "Sources/TopDeck",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Quartz"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

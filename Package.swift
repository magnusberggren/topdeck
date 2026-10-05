// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickFolder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickFolder",
            path: "Sources/QuickFolder",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Quartz"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)

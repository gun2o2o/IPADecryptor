// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPAAppStore",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "IPAAppStore",
            path: "Sources/IPAAppStore"
        ),
    ]
)

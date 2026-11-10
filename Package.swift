// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskWatch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskDiscovery", targets: ["DiskDiscovery"]),
        .executable(name: "DiskWatch", targets: ["DiskWatch"]),
        .executable(name: "disk-watch", targets: ["DiskWatchCLI"])
    ],
    targets: [
        .target(name: "DiskDiscovery", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("DiskArbitration")]),
        .executableTarget(name: "DiskWatch", dependencies: ["DiskDiscovery"]),
        .executableTarget(name: "DiskWatchCLI", dependencies: ["DiskDiscovery"]),
        .testTarget(name: "DiskDiscoveryTests", dependencies: ["DiskDiscovery"])
    ]
)

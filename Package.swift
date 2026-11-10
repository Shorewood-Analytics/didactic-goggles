// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskWatch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskDiscovery", targets: ["DiskDiscovery"]),
        .library(name: "DiskControl", targets: ["DiskControl"]),
        .executable(name: "DiskWatch", targets: ["DiskWatch"]),
        .executable(name: "disk-watch", targets: ["DiskWatchCLI"])
    ],
    targets: [
        .target(name: "DiskDiscovery", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("DiskArbitration")]),
        .target(name: "DiskControl", dependencies: ["DiskDiscovery"]),
        .executableTarget(name: "DiskWatch", dependencies: ["DiskDiscovery", "DiskControl"]),
        .executableTarget(name: "DiskWatchCLI", dependencies: ["DiskDiscovery", "DiskControl"]),
        .testTarget(name: "DiskDiscoveryTests", dependencies: ["DiskDiscovery", "DiskControl"]),
        .executableTarget(name: "SandboxProbe", dependencies: ["DiskDiscovery"], path: "Tests/SandboxProbe")
    ]
)

import AppKit
import SwiftUI
import DiskDiscovery

/// Native render of the actual view, with explicit example data for UI review.
/// Only invoked by --capture-previews; normal launches always use live discovery.
@MainActor
func capturePreviews() {
    guard let flag = CommandLine.arguments.firstIndex(of: "--capture-previews"),
          CommandLine.arguments.indices.contains(flag + 1) else { exit(2) }
    let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = DiskWindowModel()
    model.disks = [
        Disk(id: 1, bsdName: "disk4", name: "External SSD", sizeBytes: 1_000_000_000_000,
             transport: "USB", connection: .external,
             link: DetectedLink(kind: "USB link", value: "10 Gb/s", source: "Example")),
        Disk(id: 2, bsdName: "disk5", name: "Camera card", sizeBytes: 128_000_000_000,
             transport: "Secure Digital", connection: .builtInSDReader, cardType: "SDXC")
    ]
    model.usage = [
        1: DiskUsage(totalBytes: 1_000_000_000_000, freeBytes: 380_000_000_000),
        2: DiskUsage(totalBytes: 128_000_000_000, freeBytes: 28_160_000_000)
    ]
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try capture(CompactDiskWindow(model: model), size: NSSize(width: 340, height: 142),
                    to: folder.appendingPathComponent("compact-window-example.png"))
        try capture(DiskDetails(disk: model.disks[1], usage: model.usage[2], error: nil),
                    size: NSSize(width: 318, height: 310),
                    to: folder.appendingPathComponent("hover-details-example.png"))
        model.disks = []
        try capture(CompactDiskWindow(model: model), size: NSSize(width: 340, height: 112),
                    to: folder.appendingPathComponent("empty-window.png"))
        print("Captured native UI previews (explicit example disks, not detected hardware).")
    } catch {
        fputs("Preview capture failed: \(error)\n", stderr)
        exit(1)
    }
}

@MainActor
private func capture<V: View>(_ view: V, size: NSSize, to url: URL) throws {
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.frame = NSRect(origin: .zero, size: size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw NSError(domain: "Preview", code: 1)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Preview", code: 2)
    }
    try png.write(to: url)
    window.orderOut(nil)
}

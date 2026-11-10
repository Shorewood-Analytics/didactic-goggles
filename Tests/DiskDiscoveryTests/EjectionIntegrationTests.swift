import Foundation
import IOKit
import XCTest
@testable import DiskDiscovery

final class EjectionIntegrationTests: XCTestCase {
    @MainActor
    func testUnmountAndEjectControlledAPFSImage() async throws {
        try await exerciseImage(filesystem: "APFS")
    }

    @MainActor
    func testUnmountAndEjectControlledExFATImage() async throws {
        try await exerciseImage(filesystem: "ExFAT")
    }

    @MainActor
    private func exerciseImage(filesystem: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.dmg").path
        let sourceFolder = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data().write(to: sourceFolder.appendingPathComponent(".metadata_never_index"))
        let creation = filesystem == "APFS"
            ? ["create", "-srcfolder", sourceFolder.path, "-size", "128m", "-fs", filesystem, "-volname", "DiskWatchTest", path]
            : ["create", "-size", "128m", "-fs", filesystem, "-format", "UDRW", "-volname", "DiskWatchTest", path]
        _ = try run("/usr/bin/hdiutil", creation)
        let attach = try run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", path])
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: attach, format: nil) as? [String: Any])
        let entities = try XCTUnwrap(plist["system-entities"] as? [[String: Any]])
        let device = try XCTUnwrap(entities.compactMap { $0["dev-entry"] as? String }.first {
            $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
        })
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", device]) }
        let name = String(device.dropFirst(5))
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
        XCTAssertNotEqual(media, 0)
        defer { if media != 0 { IOObjectRelease(media) } }
        var id: UInt64 = 0
        XCTAssertEqual(IORegistryEntryGetRegistryEntryID(media, &id), KERN_SUCCESS)
        let disk = Disk(id: id, bsdName: name, name: "Test image", sizeBytes: 128_000_000,
                        transport: "Virtual Interface", connection: .external)
        // Only this test-owned disk image is injected. Production independently
        // revalidates against the physical external/SD discovery policy.
        let ejector = DiskEjector(eligibleDisks: { [disk] })
        // Let Disk Arbitration finish publishing the image's APFS volumes.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let usage = await DiskUsageReader().read([disk])
        XCTAssertNotNil(usage[disk.id]?.percentUsed, usage[disk.id]?.unavailableReason ?? "")
        let mount = try XCTUnwrap(entities.compactMap { $0["mount-point"] as? String }.first)
        let busyFile = URL(fileURLWithPath: mount).appendingPathComponent(".metadata_never_index")
        if filesystem == "ExFAT" { try Data().write(to: busyFile) }
        let handle = try FileHandle(forReadingFrom: busyFile)
        let busy = await ejector.ejectAll([disk])
        try handle.close()
        XCTAssertFalse(busy[0].succeeded, "An open file must prevent unmount; no force fallback")
        XCTAssertTrue(MountedSpace.snapshot().contains { $0.path == mount })

        let stale = Disk(id: UInt64.max, bsdName: "disk999999", name: "Stale", sizeBytes: 1,
                         transport: "USB", connection: .external)
        let results = await ejector.ejectAll([stale, disk, disk])
        XCTAssertEqual(results.count, 2, "Batch deduplicates attachments and continues after failure")
        XCTAssertFalse(results[0].succeeded)
        XCTAssertTrue(results[1].succeeded, results[1].error ?? "")
        XCTAssertFalse(ejector.isEjecting)
        XCTAssertFalse(MountedSpace.snapshot().contains { $0.path == mount })
        XCTAssertTrue(MediaLayout.read(disk).isEmpty, "Successful eject removes the original registry attachment")
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: executable, code: Int(process.terminationStatus))
        }
        return data
    }
}

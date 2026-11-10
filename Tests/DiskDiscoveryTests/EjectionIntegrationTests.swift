import Foundation
import IOKit
import XCTest
@testable import DiskDiscovery

final class EjectionIntegrationTests: XCTestCase {
    @MainActor
    func testUnmountAndEjectControlledAPFSImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.dmg").path
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "128m", "-fs", "APFS", "-volname", "DiskWatchTest", path])
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
        let results = await ejector.ejectAll([disk])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].succeeded, results[0].error ?? "")
        XCTAssertFalse(ejector.isEjecting)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: executable, code: Int(process.terminationStatus))
        }
        return data
    }
}

import XCTest
@testable import DiskDiscovery

final class DiskDetailsTests: XCTestCase {
    func testUSBHostAndLegacySpeedEnumerationsAreNotInterchanged() {
        XCTAssertEqual(LinkDecoder.usb(3, host: true)?.value, "480 Mb/s")
        XCTAssertEqual(LinkDecoder.usb(3, host: false)?.value, "5 Gb/s")
        XCTAssertEqual(LinkDecoder.usb(5, host: true)?.value, "10 Gb/s")
        XCTAssertEqual(LinkDecoder.usb(5, host: false)?.value, "20 Gb/s")
        XCTAssertNil(LinkDecoder.usb(0, host: true))
        XCTAssertNil(LinkDecoder.usb(99, host: true))
    }
    func testPCILinkReportsTransfersAndLanesNotCableThroughput() {
        XCTAssertEqual(LinkDecoder.pci(0x1043)?.value, "8 GT/s × 4")
        XCTAssertNil(LinkDecoder.pci(0))
        XCTAssertNil(LinkDecoder.pci(0x104f))
    }
    func testCardTypeComesFromRegistryNotCapacityOrProductName() {
        XCTAssertEqual(LinkDecoder.cardType(["Card Characteristics": ["Card Type": "SDXC"]]), "SDXC")
        XCTAssertNil(LinkDecoder.cardType(["Size": 128_000_000_000, "Product Name": "SDXC Reader"]))
        XCTAssertNil(LinkDecoder.port(["Controller Characteristics": ["Port Speed": "Automatic"]]))
        XCTAssertEqual(LinkDecoder.port(["Controller Characteristics": ["Port Speed": "Automatic (6 Gigabit)"]])?.value,
                       "Automatic (6 Gigabit)")
    }
    private func list(_ parts: [[String: Any]]) -> [String: Any] {
        ["AllDisksAndPartitions": [["DeviceIdentifier": "disk4", "Partitions": parts]]]
    }
    func testAPFSCountsSharedPoolOnlyOnce() {
        let parts: [[String: Any]] = [
            ["DeviceIdentifier": "disk4s1", "Content": "Apple_APFS"],
            ["DeviceIdentifier": "disk4s2", "Content": "Apple_APFS"]
        ]
        let apfs: [String: Any] = ["Containers": [[
            "ContainerReference": "disk6", "PhysicalStores": parts,
            "CapacityCeiling": 1000, "CapacityFree": 400,
            "Volumes": [["CapacityInUse": 200], ["CapacityInUse": 400]]
        ]]]
        let usage = UsageResolver.resolve(disk: "disk4", list: list(parts), apfs: apfs, info: [:])
        XCTAssertEqual(usage.totalBytes, 1000)
        XCTAssertEqual(usage.usedBytes, 600)
        XCTAssertEqual(usage.percentUsed, 60)
    }
    func testAPFSAcrossPhysicalDisksCannotBeAttributedToOneDisk() {
        let part: [String: Any] = ["DeviceIdentifier": "disk4s1", "Content": "Apple_APFS"]
        let apfs: [String: Any] = ["Containers": [[
            "ContainerReference": "disk6", "PhysicalStores": [part, ["DeviceIdentifier": "disk40s1"]],
            "CapacityCeiling": 1000, "CapacityFree": 400
        ]]]
        let usage = UsageResolver.resolve(disk: "disk4", list: list([part]), apfs: apfs, info: [:])
        XCTAssertNil(usage.percentUsed)
        XCTAssertEqual(usage.unavailableReason, "APFS storage spans multiple disks")
    }
    func testMixedPartitionsSumAndUnknownPartitionMakesUsageIncomplete() {
        let parts: [[String: Any]] = [
            ["DeviceIdentifier": "disk4s1", "Content": "EFI"],
            ["DeviceIdentifier": "disk4s2", "Content": "Microsoft Basic Data"],
            ["DeviceIdentifier": "disk4s3", "Content": "Apple_HFS"]
        ]
        let info: [String: [String: Any]] = [
            "disk4s2": ["VolumeTotalSpace": 100, "VolumeFreeSpace": 10],
            "disk4s3": ["VolumeTotalSpace": 900, "VolumeFreeSpace": 90]
        ]
        let usage = UsageResolver.resolve(disk: "disk4", list: list(parts), apfs: nil, info: info)
        XCTAssertEqual(usage.percentUsed, 90)
        XCTAssertNil(UsageResolver.resolve(disk: "disk4", list: list(parts), apfs: nil,
                                          info: ["disk4s2": info["disk4s2"]!]).percentUsed)
    }
    func testInvalidCountersDoNotProducePercentages() {
        let parts: [[String: Any]] = [["DeviceIdentifier": "disk4s1", "Content": "Apple_HFS"]]
        for info in [["VolumeTotalSpace": 100, "VolumeFreeSpace": 101],
                     ["VolumeTotalSpace": 100, "VolumeFreeSpace": -1],
                     ["VolumeTotalSpace": 0, "VolumeFreeSpace": 0]] {
            XCTAssertNil(UsageResolver.resolve(disk: "disk4", list: list(parts), apfs: nil,
                                              info: ["disk4s1": info]).percentUsed)
        }
    }
    @MainActor
    func testEjectionRejectsStaleAndForgedDiskIdentities() async {
        let forged = Disk(id: UInt64.max, bsdName: "disk0", name: "Forged", sizeBytes: 1,
                          transport: "USB", connection: .external)
        let ejector = DiskEjector()
        let results = await ejector.ejectAll([forged, forged])
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].succeeded)
        XCTAssertFalse(ejector.isEjecting)
    }
    func testActualDiskutilPlistsAreReadable() throws {
        let list = try Diskutil.read(["list", "-plist", "physical"])
        XCTAssertNotNil(list["AllDisksAndPartitions"])
        let apfs = try Diskutil.read(["apfs", "list", "-plist"])
        XCTAssertNotNil(apfs["Containers"])
    }
}

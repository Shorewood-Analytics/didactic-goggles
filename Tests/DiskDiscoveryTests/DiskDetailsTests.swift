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
    private func leaf(_ id: UInt64, _ name: String, parent: UInt64 = 1, content: String = "", ambiguous: Bool = false) -> MediaNode {
        MediaNode(id: id, bsdName: name, whole: false, leaf: true, content: content,
                  wholeAncestor: parent, depth: 10, ambiguous: ambiguous)
    }
    private func space(_ name: String, total: UInt64, free: UInt64, fs: String = "apfs") -> MountedSpace {
        MountedSpace(bsdName: name, path: "/Volumes/Test", filesystem: fs, total: total, free: free)
    }
    func testAPFSCountsSharedPoolOnlyOnce() {
        let nodes = [leaf(3, "disk6s1", parent: 2), leaf(4, "disk6s2", parent: 2)]
        let usage = UsageResolver.resolve(root: 1, nodes: nodes, mounted: [
            space("disk6s1", total: 1000, free: 400), space("disk6s2", total: 1000, free: 400)
        ])
        XCTAssertEqual(usage.totalBytes, 1000)
        XCTAssertEqual(usage.usedBytes, 600)
        XCTAssertEqual(usage.percentUsed, 60)
    }
    func testAmbiguousTopologyAndInconsistentAPFSCountersAreUnavailable() {
        XCTAssertNil(UsageResolver.resolve(root: 1, nodes: [leaf(2, "disk6s1", ambiguous: true)],
                                          mounted: [space("disk6s1", total: 1000, free: 400)]).percentUsed)
        let nodes = [leaf(3, "disk6s1", parent: 2), leaf(4, "disk6s2", parent: 2)]
        XCTAssertNil(UsageResolver.resolve(root: 1, nodes: nodes, mounted: [
            space("disk6s1", total: 1000, free: 400), space("disk6s2", total: 500, free: 100)
        ]).percentUsed)
    }
    func testMixedPartitionsSumAndUnknownPartitionMakesUsageIncomplete() {
        let nodes = [leaf(2, "disk4s1", content: "EFI"), leaf(3, "disk4s2"), leaf(4, "disk4s3")]
        let mounted = [space("disk4s2", total: 100, free: 10, fs: "exfat"),
                       space("disk4s3", total: 900, free: 90, fs: "hfs")]
        XCTAssertEqual(UsageResolver.resolve(root: 1, nodes: nodes, mounted: mounted).percentUsed, 90)
        XCTAssertNil(UsageResolver.resolve(root: 1, nodes: nodes, mounted: [mounted[0]]).percentUsed)
        // A similarly named disk cannot supply a missing volume's counters.
        XCTAssertNil(UsageResolver.resolve(root: 1, nodes: nodes,
                                          mounted: [space("disk40s2", total: 100, free: 10)]).percentUsed)
    }
    func testInvalidCountersDoNotProducePercentages() {
        let nodes = [leaf(2, "disk4s1")]
        for mounted in [space("disk4s1", total: 100, free: 101), space("disk4s1", total: 0, free: 0)] {
            XCTAssertNil(UsageResolver.resolve(root: 1, nodes: nodes, mounted: [mounted]).percentUsed)
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
    func testNativeMountedFilesystemCountersAreReadable() {
        let mounted = MountedSpace.snapshot()
        XCTAssertFalse(mounted.isEmpty)
        XCTAssertTrue(mounted.contains { $0.path == "/" && $0.total > 0 && $0.free <= $0.total })
    }
}

import XCTest
@testable import DiskDiscovery

final class MediaSelectionTests: XCTestCase {
    private func media() -> MediaFacts {
        MediaFacts(
            id: 42, bsdName: "disk4", name: " External SSD ", sizeBytes: 1_000_000,
            isWhole: true, hasPhysicalDevice: true, hasMediaAncestor: false,
            transport: "USB", location: "External"
        )
    }

    func testExternalBusesIncludeFixedMedia() {
        for transport in ["USB", "PCI-Express", "FireWire", "SATA", "Thunderbolt"] {
            var facts = media()
            facts.transport = transport
            let disk = facts.selectedDisk()
            XCTAssertEqual(disk?.connection, .external, transport)
            XCTAssertEqual(disk?.name, "External SSD")
            XCTAssertEqual(disk?.sizeBytes, 1_000_000)
            XCTAssertEqual(disk?.id, 42)
        }
    }

    func testBuiltInSDCardIsIncludedDespiteInternalLocation() {
        var facts = media()
        facts.transport = "Secure Digital"
        facts.location = "Internal"
        XCTAssertEqual(facts.selectedDisk()?.connection, .builtInSDReader)
    }

    func testExternalSDReaderRemainsExternal() {
        var facts = media()
        facts.transport = "Secure Digital"
        XCTAssertEqual(facts.selectedDisk()?.connection, .external)
    }

    func testInternalSystemDisksAreExcluded() {
        for transport in ["Apple Fabric", "PCI-Express", "SATA", "USB"] {
            var facts = media()
            facts.transport = transport
            facts.location = "Internal"
            XCTAssertNil(facts.selectedDisk(), transport)
        }
    }

    func testPartitionsAndSynthesizedMediaAreExcluded() {
        var partition = media()
        partition.isWhole = false
        XCTAssertNil(partition.selectedDisk())
        var container = media()
        container.hasMediaAncestor = true
        XCTAssertNil(container.selectedDisk())
        var synthesized = media()
        synthesized.hasPhysicalDevice = false
        XCTAssertNil(synthesized.selectedDisk())
    }

    func testVirtualMediaIsExcludedEvenWithExternalLocation() {
        var facts = media()
        facts.transport = "Virtual Interface"
        XCTAssertNil(facts.selectedDisk())
    }

    func testUnknownAndIncompleteFactsAreNotGuessed() {
        for location in [nil, "Internal/External", "File", "RAM", ""] as [String?] {
            var facts = media()
            facts.location = location
            XCTAssertNil(facts.selectedDisk())
        }
        var facts = media()
        facts.transport = nil
        XCTAssertNil(facts.selectedDisk())
        facts = media()
        facts.bsdName = nil
        XCTAssertNil(facts.selectedDisk())
        facts = media()
        facts.sizeBytes = 0
        XCTAssertNil(facts.selectedDisk())
    }

    func testMissingProductNameFallsBackToBSDName() {
        var facts = media()
        facts.name = "  "
        XCTAssertEqual(facts.selectedDisk()?.name, "disk4")
    }

    func testDiskHasLosslessJSONRepresentation() throws {
        let disk = try XCTUnwrap(media().selectedDisk())
        XCTAssertEqual(try JSONDecoder().decode(Disk.self, from: JSONEncoder().encode(disk)), disk)
    }
}

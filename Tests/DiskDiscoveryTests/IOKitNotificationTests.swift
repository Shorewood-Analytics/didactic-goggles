import Foundation
import XCTest
@testable import DiskDiscovery

final class IOKitNotificationTests: XCTestCase {
    /// A temporary RAM disk exercises real IOKit callbacks without touching a
    /// physical disk. It must trigger notifications but remain out of inventory.
    @MainActor
    func testNativeArrivalAndRemovalNotifications() async throws {
        let source = IOKitDiskSource()
        var notifications = 0
        try source.start { notifications += 1 }
        defer { source.stop() }

        let output = try hdiutil(["attach", "-nomount", "ram://2048"])
        let device = try XCTUnwrap(output.split(whereSeparator: { $0.isWhitespace }).first)
        XCTAssertNotNil(String(device).range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression))
        let path = String(device)
        var attached = true
        defer { if attached { _ = try? hdiutil(["detach", path]) } }

        let arrived = try await waitUntil { notifications > 0 }
        XCTAssertTrue(arrived, "IOKit did not deliver the arrival notification")
        XCTAssertFalse(try source.snapshot().contains { "/dev/\($0.bsdName)" == path })

        let beforeRemoval = notifications
        _ = try hdiutil(["detach", path])
        attached = false
        let removed = try await waitUntil { notifications > beforeRemoval }
        XCTAssertTrue(removed, "IOKit did not deliver the removal notification")
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private func hdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "IOKitNotificationTests.hdiutil", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

import XCTest
@testable import DiskDiscovery

private struct TestFailure: Error {}

@MainActor
private final class FakeSource: DiskSource {
    var disks: [Disk] = []
    var callbacks: [@MainActor () -> Void] = []
    var starts = 0
    var stops = 0
    var scans = 0
    var failStart = false
    var failSnapshot = false

    func start(onChange: @escaping @MainActor () -> Void) throws {
        starts += 1
        callbacks.append(onChange)
        if failStart { throw TestFailure() }
    }

    func snapshot() throws -> [Disk] {
        scans += 1
        if failSnapshot { throw TestFailure() }
        return disks
    }

    func stop() { stops += 1 }
}

final class DiskMonitorTests: XCTestCase {
    private func disk(_ id: UInt64 = 1) -> Disk {
        Disk(id: id, bsdName: "disk\(id)", name: "Test", sizeBytes: 100,
             transport: "USB", connection: .external)
    }

    @MainActor
    func testStartupFindsAlreadyConnectedDisksAndStartIsIdempotent() async throws {
        let source = FakeSource()
        source.disks = [disk(2), disk(1)]
        let monitor = DiskMonitor(source: source)
        var notifications = 0
        monitor.onChange = { notifications += 1 }
        try monitor.start()
        try monitor.start()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(monitor.disks.map(\.id), [1, 2])
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(notifications, 1)
    }

    @MainActor
    func testArrivalRemovalAndDuplicateEventsReconcileSnapshots() async throws {
        let source = FakeSource()
        let monitor = DiskMonitor(source: source)
        var notifications = 0
        monitor.onChange = { notifications += 1 }
        try monitor.start()
        source.disks = [disk()]
        source.callbacks[0]()
        source.callbacks[0]()
        XCTAssertEqual(monitor.disks, [disk()])
        XCTAssertEqual(notifications, 2)
        source.disks = []
        source.callbacks[0]()
        XCTAssertTrue(monitor.disks.isEmpty)
        XCTAssertEqual(notifications, 3)
    }

    @MainActor
    func testOldNotificationsCannotAffectStoppedOrRestartedMonitor() async throws {
        let source = FakeSource()
        let monitor = DiskMonitor(source: source)
        try monitor.start()
        let oldCallback = source.callbacks[0]
        monitor.stop()
        source.disks = [disk()]
        oldCallback()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(monitor.disks.isEmpty)
        XCTAssertEqual(source.scans, 1)
        try monitor.start()
        source.disks = []
        oldCallback()
        XCTAssertEqual(monitor.disks, [disk()])
        source.callbacks[1]()
        XCTAssertTrue(monitor.disks.isEmpty)
    }

    @MainActor
    func testStartupFailureCleansUpAndCanBeRetried() async throws {
        for failAtRegistration in [true, false] {
            let source = FakeSource()
            source.failStart = failAtRegistration
            source.failSnapshot = !failAtRegistration
            let monitor = DiskMonitor(source: source)
            XCTAssertThrowsError(try monitor.start())
            XCTAssertFalse(monitor.isRunning)
            XCTAssertNotNil(monitor.lastError)
            XCTAssertEqual(source.stops, 1)
            source.failStart = false
            source.failSnapshot = false
            try monitor.start()
            XCTAssertTrue(monitor.isRunning)
            XCTAssertNil(monitor.lastError)
        }
    }

    @MainActor
    func testFailedRefreshPreservesSnapshotAndExposesErrorUntilRecovery() async throws {
        let source = FakeSource()
        source.disks = [disk()]
        let monitor = DiskMonitor(source: source)
        try monitor.start()
        source.failSnapshot = true
        source.callbacks[0]()
        XCTAssertEqual(monitor.disks, [disk()])
        XCTAssertNotNil(monitor.lastError)
        source.failSnapshot = false
        source.disks = []
        monitor.refresh()
        XCTAssertTrue(monitor.disks.isEmpty)
        XCTAssertNil(monitor.lastError)
    }

    @MainActor
    func testCallbackDoesNotRetainMonitor() async throws {
        let source = FakeSource()
        var monitor: DiskMonitor? = DiskMonitor(source: source)
        weak var weakMonitor = monitor
        try monitor?.start()
        monitor = nil
        XCTAssertNil(weakMonitor)
        source.callbacks[0]()
    }

    @MainActor
    func testRealIOKitRegistrationCanStartStopAndRestart() async throws {
        let monitor = DiskMonitor()
        for _ in 0..<3 {
            try monitor.start()
            XCTAssertTrue(monitor.isRunning)
            monitor.stop()
            XCTAssertFalse(monitor.isRunning)
        }
    }
}

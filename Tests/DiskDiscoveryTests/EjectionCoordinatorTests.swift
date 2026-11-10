import XCTest
@testable import DiskDiscovery

final class EjectionCoordinatorTests: XCTestCase {
    private var disk: Disk {
        Disk(id: 1, bsdName: "disk4", name: "Fixture", sizeBytes: 100, transport: "USB", connection: .external)
    }
    private var blocker: DiskBlocker {
        DiskBlocker(pid: 100, startedAt: "123", name: "Editor", executable: "/Editor", paths: ["/Volumes/Fixture"])
    }
    @MainActor
    func testCleanDiskDoesNotInspectOrCloseApplications() async {
        let coordinator = EjectionCoordinator(eject: { _ in .init(error: nil) }, inspect: { _ in
            XCTFail("No diagnosis needed for successful ejection"); return .init(blockers: [])
        }, release: { _, _, _ in
            XCTFail("Must not touch apps"); return .init(succeeded: false, detail: "unexpected")
        }, verify: { _ in true })
        let result = await coordinator.ejectAll([disk, disk])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].succeeded)
    }
    @MainActor
    func testClosesOnlyAffectedDocumentsAndStopsImmediatelyWhenEjected() async {
        var released = false
        var levels: [ReleaseLevel] = []
        let blocker = blocker
        let coordinator = EjectionCoordinator(eject: { _ in .init(error: released ? nil : "busy", isBusy: !released) },
            inspect: { _ in .init(blockers: [blocker]) }, release: { _, found, level in
                XCTAssertEqual(found, blocker); levels.append(level); released = true
                return .init(succeeded: true, detail: "saved and closed")
            }, verify: { _ in true })
        let result = await coordinator.ejectAll([disk])
        XCTAssertTrue(result[0].succeeded)
        XCTAssertEqual(levels, [.closeDocuments])
    }
    @MainActor
    func testEscalatesOnlyTheStillBlockingApplication() async {
        var quit = false
        var levels: [ReleaseLevel] = []
        let blocker = blocker
        let coordinator = EjectionCoordinator(eject: { _ in .init(error: quit ? nil : "busy", isBusy: !quit) },
            inspect: { _ in .init(blockers: [blocker]) }, release: { _, _, level in
                levels.append(level); quit = level == .quitBlockingApp
                return .init(succeeded: true, detail: "completed")
            }, verify: { _ in true })
        let result = await coordinator.ejectAll([disk])
        XCTAssertTrue(result[0].succeeded)
        XCTAssertEqual(levels, [.closeDocuments, .quitBlockingApp])
    }
    @MainActor
    func testFailedSavePreventsQuittingTheApplication() async {
        var levels: [ReleaseLevel] = []
        let blocker = blocker
        let coordinator = EjectionCoordinator(eject: { _ in .init(error: "busy", isBusy: true) },
            inspect: { _ in .init(blockers: [blocker]) }, release: { _, _, level in
                levels.append(level); return .init(succeeded: false, detail: "save failed")
            }, verify: { _ in XCTFail("Not ejected"); return false })
        let results = await coordinator.ejectAll([disk])
        XCTAssertFalse(results[0].succeeded)
        XCTAssertEqual(levels, [.closeDocuments])
        XCTAssertTrue(results[0].events.contains { $0.detail == "save failed" })
    }
    @MainActor
    func testFormerBlockerIsNotClosedAndUnverifiedSuccessIsFailure() async {
        var inspections = 0
        let blocker = blocker
        let coordinator = EjectionCoordinator(eject: { _ in .init(error: "busy", isBusy: true) }, inspect: { _ in
            inspections += 1
            return .init(blockers: inspections == 1 ? [blocker] : [])
        }, release: { _, _, _ in
            XCTFail("Holder already released"); return .init(succeeded: false, detail: "unexpected")
        }, verify: { _ in false })
        let result = await coordinator.ejectAll([disk])
        XCTAssertFalse(result[0].succeeded)
        let falseSuccess = EjectionCoordinator(eject: { _ in .init(error: nil) }, inspect: { _ in .init(blockers: []) },
            release: { _, _, _ in .init(succeeded: false, detail: "unexpected") }, verify: { _ in false })
        let falseResult = await falseSuccess.ejectAll([disk])
        XCTAssertFalse(falseResult[0].succeeded)
    }
}

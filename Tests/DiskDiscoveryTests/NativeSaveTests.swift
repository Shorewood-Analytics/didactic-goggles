import Foundation
import AppKit
import XCTest
import DiskDiscovery
@testable import DiskControl

final class NativeSaveTests: XCTestCase {
    @MainActor
    func testTextEditSavesChangedDocumentBeforeQuitting() async throws {
        // Opt in only in a disposable GUI session, because this controls a real
        // application and may need the normal macOS Automation authorization.
        guard ProcessInfo.processInfo.environment["DISK_WATCH_AUTOMATION_TESTS"] == "1" else {
            throw XCTSkip("Real-app save qualification requires an authorized disposable GUI session")
        }
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty,
                      "Qualification requires TextEdit to start closed")
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("save-proof.txt")
        try "Original\n".write(to: path, atomically: true, encoding: .utf8)
        let marker = "DiskWatch saved unsaved work " + UUID().uuidString
        let setup = await ScriptRunner.run(#"""
        on run argv
            with timeout of 30 seconds
                tell application "TextEdit"
                    open POSIX file (item 1 of argv)
                    set text of front document to (item 2 of argv)
                end tell
            end timeout
            return "Document changed"
        end run
        """#, arguments: [path.path, marker])
        XCTAssertTrue(setup.succeeded, setup.output)
        guard setup.succeeded else { return }
        let application = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first)
        let holder = try XCTUnwrap(ProcessBlockerInspector.identity(application.processIdentifier, paths: [path.path]))
        let fixture = Disk(id: UInt64.max, bsdName: "disk999999", name: "Save qualification", sizeBytes: 1,
                           transport: "Virtual Interface", connection: .external)
        let result = await ApplicationReleaser().release(fixture, blocker: holder, level: .quitBlockingApp)
        XCTAssertTrue(result.succeeded, result.detail)
        XCTAssertTrue(application.isTerminated)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains(marker), "Verify saved file bytes after the app has exited")
    }
}

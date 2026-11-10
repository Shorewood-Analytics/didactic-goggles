import Foundation
import AppKit
import XCTest
@testable import DiskControl

final class NativeSaveTests: XCTestCase {
    @MainActor
    func testTextEditSavesChangedDocumentBeforeQuitting() async throws {
        // Opt in only in a disposable GUI session, because this controls a real
        // application and may need the normal macOS Automation authorization.
        guard ProcessInfo.processInfo.environment["DISK_WATCH_AUTOMATION_TESTS"] == "1" else {
            throw XCTSkip("Real-app save qualification requires an authorized disposable GUI session")
        }
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
                    -- Compiling the production script can launch TextEdit to read
                    -- its dictionary. A running app is safe only with no documents.
                    if (count of documents) is not 0 then error "Qualification requires TextEdit to have no existing documents"
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
        // Qualify the actual save/close script with an isolated fixture directory.
        // ApplicationReleaser itself requires a real, currently held disk and must
        // reject forged disk identities instead of bypassing that safety check.
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let result = await ScriptRunner.run(ApplicationReleaser.documentsScript,
            arguments: ["com.apple.TextEdit", "quitBlockingApp", recovery.path, directory.path])
        XCTAssertTrue(result.succeeded, result.output)
        let deadline = Date().addingTimeInterval(10)
        while !application.isTerminated, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(application.isTerminated)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains(marker), "Verify saved file bytes after the app has exited")
    }
}

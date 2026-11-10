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
        // osacompile can start TextEdit only to fetch its dictionary. Explicitly
        // open our document through Launch Services so normal GUI startup finishes
        // before asking it to handle scripted document operations.
        let applicationURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let application = try await NSWorkspace.shared.open([path], withApplicationAt: applicationURL,
                                                            configuration: configuration)
        let launchDeadline = Date().addingTimeInterval(15)
        while !application.isFinishedLaunching, !application.isTerminated, Date() < launchDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(application.isFinishedLaunching && !application.isTerminated,
                      "TextEdit did not finish launching (PID \(application.processIdentifier))")
        guard application.isFinishedLaunching, !application.isTerminated else { return }
        let diagnostics = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            guard !Task.isCancelled,
                  let runnerTemporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { return }
            let folder = URL(fileURLWithPath: runnerTemporary).appendingPathComponent("diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", folder.appendingPathComponent("native-save-during-automation.png").path]
            do { try capture.run(); capture.waitUntilExit() }
            catch { print("Could not capture automation diagnostics:", error) }
        }
        defer { diagnostics.cancel() }
        let setup = await ScriptRunner.run(#"""
        on run argv
            with timeout of 30 seconds
                tell application "TextEdit"
                    activate
                    -- The only document must be the test-owned file opened above.
                    -- Never save or close documents left by another application user.
                    set docs to get every document
                    if (count docs) is not 1 then error "Qualification requires only the test document to be open"
                    set actualFile to (POSIX file (path of front document)) as alias
                    set expectedFile to (POSIX file (item 1 of argv)) as alias
                    if actualFile is not expectedFile then error "TextEdit front document is not the test fixture"
                    set text of front document to (item 2 of argv)
                end tell
            end timeout
            return "Document changed"
        end run
        """#, arguments: [path.path, marker])
        diagnostics.cancel()
        XCTAssertTrue(setup.succeeded, setup.output)
        guard setup.succeeded else { return }
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

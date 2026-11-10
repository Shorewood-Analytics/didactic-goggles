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
        let volume = directory.appendingPathComponent("disk")
        let otherVolume = directory.appendingPathComponent("disk-other")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherVolume, withIntermediateDirectories: true)
        let path = volume.appendingPathComponent("save-proof.txt")
        let otherPath = otherVolume.appendingPathComponent("keep-open.txt")
        try "Other original\n".write(to: otherPath, atomically: true, encoding: .utf8)
        try "Original\n".write(to: path, atomically: true, encoding: .utf8)
        let marker = "DiskWatch saved unsaved work " + UUID().uuidString
        // Launch the real application with only test-owned files before sending
        // scripting events. No production disk-identity checks are bypassed.
        let applicationURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let application = try await NSWorkspace.shared.open([path, otherPath], withApplicationAt: applicationURL,
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
                    set expectedFile to (POSIX file (item 1 of argv)) as alias
                    set otherFile to (POSIX file (item 3 of argv)) as alias
                    set docs to get every document
                    repeat with d in docs
                        set p to path of d
                        if p is missing value then
                            if modified of d or (text of d as text) is not "" then error "Unexpected unsaved work in qualification session"
                            close d saving yes
                        else
                            set actualFile to (POSIX file p) as alias
                            if actualFile is not expectedFile and actualFile is not otherFile then error "Unexpected document in qualification session"
                            set text of d to (item 2 of argv)
                        end if
                    end repeat
                    make new document with properties {text:((item 2 of argv) & " untitled")}
                end tell
            end timeout
            return "Document changed"
        end run
        """#, arguments: [path.path, marker, otherPath.path])
        diagnostics.cancel()
        XCTAssertTrue(setup.succeeded, setup.output)
        guard setup.succeeded else { return }
        // Qualify the actual save/close script with an isolated fixture directory.
        // ApplicationReleaser itself requires a real, currently held disk and must
        // reject forged disk identities instead of bypassing that safety check.
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let root = volume.resolvingSymlinksInPath().path
        let pathDiagnostics = await ScriptRunner.run(#"""
        tell application "TextEdit"
            set report to {}
            repeat with d in (get every document)
                set end of report to ((name of d) as text) & ": " & ((path of d) as text)
            end repeat
            return report
        end tell
        """#, arguments: [])
        print("Native save root:", root, "document paths:", pathDiagnostics.output)
        let targeted = await ScriptRunner.run(ApplicationReleaser.documentsScript,
            arguments: ["com.apple.TextEdit", "closeDocuments", recovery.path, root])
        print("Targeted native save result:", targeted.output)
        XCTAssertTrue(targeted.succeeded, targeted.output)
        guard targeted.succeeded else { return }
        XCTAssertFalse(application.isTerminated, "Targeted document closure must leave the app running")
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains(marker))
        let remaining = await ScriptRunner.run("tell application \"TextEdit\" to return count of documents", arguments: [])
        XCTAssertTrue(remaining.succeeded, remaining.output)
        XCTAssertEqual(remaining.output, "2", "The unrelated and untitled documents must remain open")
        let result = await ScriptRunner.run(ApplicationReleaser.documentsScript,
            arguments: ["com.apple.TextEdit", "quitBlockingApp", recovery.path, root])
        print("Native quit/recovery result:", result.output)
        XCTAssertTrue(result.succeeded, result.output)
        guard result.succeeded else { return }
        let deadline = Date().addingTimeInterval(10)
        while !application.isTerminated, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(application.isTerminated)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains(marker), "Verify saved bytes after exit")
        XCTAssertTrue(try String(contentsOf: otherPath, encoding: .utf8).contains(marker), "Quit must save remaining modified work")
        let recovered = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        XCTAssertFalse(recovered.isEmpty, "Untitled work must be recovered before quitting")
        XCTAssertTrue(try recovered.contains { try Data(contentsOf: $0).range(of: Data((marker + " untitled").utf8)) != nil })
    }
}

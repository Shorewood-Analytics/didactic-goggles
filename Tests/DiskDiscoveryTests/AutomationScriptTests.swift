import Foundation
import XCTest
@testable import DiskControl

final class AutomationScriptTests: XCTestCase {
    @MainActor
    func testNativeAppleScriptCompilerAcceptsReleaseScripts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, script) in [ApplicationReleaser.finderScript, ApplicationReleaser.documentsScript].enumerated() {
            let source = directory.appendingPathComponent("script-\(index).applescript")
            try script.write(to: source, atomically: true, encoding: .utf8)
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", directory.appendingPathComponent("script-\(index).scpt").path, source.path]
            process.standardError = errors
            try process.run()
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: message, as: UTF8.self))
        }
    }
}

import Foundation
import Darwin

struct ScriptResult {
    let succeeded: Bool
    let output: String
}

enum ScriptRunner {
    /// Arguments are passed as argv, never interpolated into executable script.
    static func run(_ source: String, arguments: [String]) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source] + arguments
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + 40)
                    timer.setEventHandler { if process.isRunning { process.terminate() } }
                    timer.resume()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    timer.cancel()
                    process.waitUntilExit()
                    continuation.resume(returning: ScriptResult(succeeded: process.terminationStatus == 0,
                        output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No script result"))
                } catch {
                    continuation.resume(returning: ScriptResult(succeeded: false, output: error.localizedDescription))
                }
            }
        }
    }
}

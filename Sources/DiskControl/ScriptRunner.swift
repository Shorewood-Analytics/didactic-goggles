import Foundation
import Darwin

struct ScriptResult {
    let succeeded: Bool
    let output: String
}

private final class ScriptDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.lock(); expired = true; lock.unlock() }
    var hasExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

enum ScriptRunner {
    /// Arguments are passed as argv, never interpolated into executable script.
    static func run(_ source: String, arguments: [String], timeout: TimeInterval = 40) async -> ScriptResult {
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
                    let deadline = ScriptDeadline()
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler {
                        if process.isRunning { deadline.expire(); process.terminate() }
                    }
                    // This is only our osascript child. Never signal the target
                    // application, whose save operation may still be in progress.
                    let finalTimer = DispatchSource.makeTimerSource(queue: .global())
                    finalTimer.schedule(deadline: .now() + timeout + 2)
                    finalTimer.setEventHandler {
                        if process.isRunning {
                            deadline.expire()
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    timer.resume()
                    finalTimer.resume()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    // Keep both deadlines active even if the child closes its
                    // output before exiting.
                    process.waitUntilExit()
                    timer.cancel()
                    finalTimer.cancel()
                    let timedOut = deadline.hasExpired
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "No script result"
                    continuation.resume(returning: ScriptResult(
                        succeeded: !timedOut && process.terminationStatus == 0,
                        output: timedOut ? "AppleScript timed out; stopped the automation helper. " + message : message))
                } catch {
                    continuation.resume(returning: ScriptResult(succeeded: false, output: error.localizedDescription))
                }
            }
        }
    }
}

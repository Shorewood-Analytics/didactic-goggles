import Foundation
import AppKit
import Darwin
import DiskDiscovery

@MainActor
public final class ApplicationReleaser {
    public init() {}

    public func release(_ disk: Disk, blocker: DiskBlocker, level: ReleaseLevel) async -> ReleaseOutcome {
        guard blocker.pid != ProcessInfo.processInfo.processIdentifier,
              let current = ProcessBlockerInspector.identity(blocker.pid), current.id == blocker.id,
              current.executable == blocker.executable else {
            return .init(succeeded: false, detail: "Process exited, changed identity, or belongs to Disk Watch")
        }
        guard let application = Self.owningApplication(blocker.pid),
              let bundleID = application.bundleIdentifier else {
            return .init(succeeded: false, detail: "\(blocker.name) (PID \(blocker.pid)) is a background process; no save/checkpoint adapter is registered")
        }
        let roots = DiskInspection.read(disk).volumes.map(\.path)
        if bundleID == "com.apple.finder" {
            let source = level == .closeDocuments ? Self.finderScript : Self.finderQuitScript
            let result = await ScriptRunner.run(source, arguments: roots)
            if level == .quitBlockingApp, result.succeeded {
                let deadline = Date().addingTimeInterval(10)
                while !application.isTerminated, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                return .init(succeeded: application.isTerminated,
                             detail: application.isTerminated ? "Finder exited after its windows were closed" : "Finder has not finished quitting")
            }
            return .init(succeeded: result.succeeded, detail: result.output)
        }
        let recovery = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DiskWatch/Recovered Work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true) }
        catch { return .init(succeeded: false, detail: "Cannot prepare work-recovery folder: \(error.localizedDescription)") }
        let result = await ScriptRunner.run(Self.documentsScript,
            arguments: [bundleID, level.rawValue, recovery.path] + roots)
        guard result.succeeded else { return .init(succeeded: false, detail: result.output) }
        if level == .quitBlockingApp {
            let deadline = Date().addingTimeInterval(10)
            while !application.isTerminated, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard application.isTerminated else {
                return .init(succeeded: false, detail: "\(blocker.name) has not finished saving/quitting: \(result.output)")
            }
        }
        return .init(succeeded: true, detail: result.output)
    }

    private static func owningApplication(_ originalPID: Int32) -> NSRunningApplication? {
        var pid = originalPID
        var seen: Set<Int32> = []
        var fallback: NSRunningApplication?
        while pid > 1, seen.insert(pid).inserted, seen.count < 16 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == geteuid() else { return fallback }
            if let app = NSRunningApplication(processIdentifier: pid) {
                if app.activationPolicy == .regular || app.bundleIdentifier == "com.apple.finder" { return app }
                fallback = fallback ?? app
            }
            pid = Int32(info.pbi_ppid)
        }
        return fallback
    }

    // Finder has no editable documents: close only windows on the affected disk.
    static let finderScript = #"""
    on run roots
        set closedCount to 0
        with timeout of 30 seconds
            tell application "Finder"
                repeat with w in (get every Finder window)
                    try
                        set p to POSIX path of ((target of w) as alias)
                        repeat with root in roots
                            if p is (root as text) or p starts with ((root as text) & "/") then
                                close w
                                set closedCount to closedCount + 1
                                exit repeat
                            end if
                        end repeat
                    end try
                end repeat
            end tell
        end timeout
        return "Closed " & closedCount & " Finder window(s) on the disk"
    end run
    """#

    static let finderQuitScript = #"""
    with timeout of 30 seconds
        tell application "Finder" to quit
    end timeout
    return "Requested Finder exit after targeted window closure"
    """#

    // Standard document Apple events. Saving and modified-state verification
    // precede every close. Unsupported commands fail visibly; no discard command.
    static let documentsScript = #"""
    on run argv
        set targetID to item 1 of argv
        set mode to item 2 of argv
        set recovery to item 3 of argv
        set roots to {}
        if (count argv) > 3 then set roots to items 4 thru -1 of argv
        set savedCount to 0
        set closedCount to 0
        with timeout of 30 seconds
            if not (application id targetID is running) then return "Application already exited"
            using terms from application "TextEdit"
            tell application id targetID
                set docs to get every document
                repeat with d in docs
                    set docPath to ""
                    try
                        set docPath to POSIX path of ((get «class file» of d) as alias)
                    on error
                        try
                            set docPath to (get path of d) as text
                        end try
                    end try
                    if docPath is "missing value" then set docPath to ""
                    set affected to (mode is "quitBlockingApp")
                    repeat with root in roots
                        if docPath is (root as text) or docPath starts with ((root as text) & "/") then set affected to true
                    end repeat
                    if affected then
                        set changed to get modified of d
                        if changed then
                            if docPath is "" then
                                set recoveredPath to recovery & "/Recovered-" & (savedCount + 1)
                                save d in (POSIX file recoveredPath)
                            else
                                save d
                            end if
                            if (get modified of d) then error "Document remains modified after saving; closure stopped"
                            set savedCount to savedCount + 1
                        end if
                        close d saving yes
                        set closedCount to closedCount + 1
                    end if
                end repeat
                if mode is "quitBlockingApp" then
                    quit saving yes
                end if
            end tell
            end using terms from
        end timeout
        return "Saved " & savedCount & "; closed " & closedCount & "; recovery folder: " & recovery
    end run
    """#
}

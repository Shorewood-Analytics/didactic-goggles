import Foundation
import AppKit
import Darwin
import DiskDiscovery

@MainActor
public final class ApplicationReleaser {
    private let inspector = ProcessBlockerInspector()
    public init() {}

    public func release(_ disk: Disk, blocker: DiskBlocker, level: ReleaseLevel) async -> ReleaseOutcome {
        guard blocker.pid != ProcessInfo.processInfo.processIdentifier,
              let current = ProcessBlockerInspector.identity(blocker.pid), current.id == blocker.id,
              current.executable == blocker.executable else {
            return .init(succeeded: false, detail: "Process exited, changed identity, or belongs to Disk Watch")
        }
        // A shell/helper's parent is not necessarily its owning application.
        // Never close Terminal or an unrelated ancestor to release a child process.
        guard let application = NSRunningApplication(processIdentifier: blocker.pid),
              application.activationPolicy == .regular || application.bundleIdentifier == "com.apple.finder",
              let bundleID = application.bundleIdentifier,
              application.executableURL?.path == blocker.executable,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count == 1 else {
            return .init(succeeded: false, detail: "\(blocker.name) (PID \(blocker.pid)) is a background process; no save/checkpoint adapter is registered")
        }
        let inspection = DiskInspection.read(disk)
        let roots = inspection.volumes.map(\.path)
        guard inspection.presence == .present, !roots.isEmpty,
              !roots.contains("/"), !roots.contains("/System/Volumes/Data") else {
            return .init(succeeded: false, detail: "Disk is no longer mounted or its identity cannot be safely confirmed")
        }
        let fresh = await inspector.inspect(disk)
        guard !Task.isCancelled, !application.isTerminated,
              fresh.blockers.contains(where: { $0.id == blocker.id && $0.executable == blocker.executable }) else {
            return .init(succeeded: false, detail: "Process no longer holds this disk, or ejection was cancelled")
        }
        if bundleID == "com.apple.finder" {
            guard level == .closeDocuments else {
                return .init(succeeded: false, detail: "Finder still holds the disk; its other windows will not be closed")
            }
            let result = await ScriptRunner.run(Self.finderScript, arguments: roots)
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

    // Finder has no editable documents: close only windows on the affected disk.
    static let finderScript = #"""
    on run roots
        set closedCount to 0
        with timeout of 30 seconds
            tell application "Finder"
                repeat with w in (get every Finder window)
                    try
                        set p to POSIX path of ((target of w) as alias)
                        considering case
                            repeat with root in roots
                                if p is (root as text) or p starts with ((root as text) & "/") then
                                    close w
                                    set closedCount to closedCount + 1
                                    exit repeat
                                end if
                            end repeat
                        end considering
                    end try
                end repeat
            end tell
        end timeout
        return "Closed " & closedCount & " Finder window(s) on the disk"
    end run
    """#

    // Standard document Apple events. Saving and modified-state verification
    // precede every close. Unsupported commands fail visibly; no discard command.
    // Use Cocoa Standard Suite codes directly: importing another application's
    // terminology can launch that application merely to compile this script.
    // Codes: developer.apple.com/library/archive/samplecode/Sketch/Listings/Sketch_sdef.html
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
            tell application id targetID
                set docs to get every «class docu»
                repeat with d in docs
                    set docPath to ""
                    try
                        set docPath to POSIX path of ((get «class file» of d) as alias)
                    on error
                        try
                            set docPath to (get «class ppth» of d) as text
                        end try
                    end try
                    if docPath is "missing value" then set docPath to ""
                    set affected to (mode is "quitBlockingApp")
                    considering case
                        repeat with root in roots
                            if docPath is (root as text) or docPath starts with ((root as text) & "/") then set affected to true
                        end repeat
                    end considering
                    if affected then
                        set changed to get «class imod» of d
                        if changed then
                            if docPath is "" then
                                set recoveredPath to recovery & "/Recovered-" & (savedCount + 1)
                                «event coresave» d given «class kfil»: (POSIX file recoveredPath)
                            else
                                «event coresave» d
                            end if
                            if (get «class imod» of d) then error "Document remains modified after saving; closure stopped"
                            set savedCount to savedCount + 1
                        end if
                        «event coreclos» d given «class savo»: yes
                        set closedCount to closedCount + 1
                    end if
                end repeat
                if mode is "quitBlockingApp" then
                    «event aevtquit» given «class savo»: yes
                end if
            end tell
        end timeout
        return "Saved " & savedCount & "; closed " & closedCount & "; recovery folder: " & recovery
    end run
    """#
}

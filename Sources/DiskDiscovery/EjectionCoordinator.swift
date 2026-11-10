import Foundation

public struct DiskBlocker: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(pid):\(startedAt)" }
    public let pid: Int32
    public let startedAt: String
    public let name: String
    public let executable: String
    public let paths: [String]
    public init(pid: Int32, startedAt: String, name: String, executable: String, paths: [String]) {
        self.pid = pid; self.startedAt = startedAt; self.name = name
        self.executable = executable; self.paths = paths
    }
}

public struct BlockerReport: Codable, Equatable, Sendable {
    public var blockers: [DiskBlocker]
    public var limitations: [String]
    public init(blockers: [DiskBlocker], limitations: [String] = []) {
        self.blockers = blockers; self.limitations = limitations
    }
}

public enum ReleaseLevel: String, Codable, Sendable {
    case closeDocuments, quitBlockingApp
}

public struct ReleaseOutcome: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let detail: String
    public let mayEscalate: Bool
    public init(succeeded: Bool, detail: String, mayEscalate: Bool = false) {
        self.succeeded = succeeded; self.detail = detail; self.mayEscalate = mayEscalate
    }
}

public struct EjectionEvent: Codable, Equatable, Sendable {
    public let diskID: UInt64
    public let stage: String
    public let detail: String
    public let date: Date
    public init(diskID: UInt64, stage: String, detail: String) {
        self.diskID = diskID; self.stage = stage; self.detail = detail; self.date = Date()
    }
}

public struct CoordinatedEjectionResult: Codable, Equatable, Sendable {
    public let disk: Disk
    public let succeeded: Bool
    public let error: String?
    public let diagnosis: BlockerReport?
    public let events: [EjectionEvent]
}

public struct EjectionAttempt: Sendable {
    public let error: String?
    public let isBusy: Bool
    public init(error: String?, isBusy: Bool = false) { self.error = error; self.isBusy = isBusy }
}

/// Portable orchestration policy. Platform adapters provide inspection and
/// save/close operations; the same coordinator is used by GUI and headless CLI.
@MainActor
public final class EjectionCoordinator {
    public typealias Eject = (Disk) async -> EjectionAttempt
    public typealias Inspect = (Disk) async -> BlockerReport
    public typealias Release = (Disk, DiskBlocker, ReleaseLevel) async -> ReleaseOutcome
    public typealias Verify = (Disk) async -> Bool
    private let eject: Eject
    private let inspect: Inspect
    private let release: Release
    private let verify: Verify
    private let begin: () -> Bool
    private let end: () -> Void
    public private(set) var isRunning = false

    public init(eject: @escaping Eject, inspect: @escaping Inspect,
                release: @escaping Release, verify: @escaping Verify,
                begin: @escaping () -> Bool = { true }, end: @escaping () -> Void = {}) {
        self.eject = eject; self.inspect = inspect; self.release = release; self.verify = verify
        self.begin = begin; self.end = end
    }

    public func ejectAll(_ disks: [Disk], progress: (EjectionEvent) -> Void = { _ in }) async -> [CoordinatedEjectionResult] {
        var seen: Set<UInt64> = []
        let targets = disks.filter { seen.insert($0.id).inserted }
        guard !isRunning, begin() else {
            return targets.map { .init(disk: $0, succeeded: false, error: "Ejection already in progress", diagnosis: nil, events: []) }
        }
        isRunning = true
        defer { isRunning = false; end() }
        var results: [CoordinatedEjectionResult] = []
        for disk in targets {
            guard !Task.isCancelled else {
                results.append(.init(disk: disk, succeeded: false, error: "Ejection cancelled", diagnosis: nil, events: []))
                continue
            }
            var events: [EjectionEvent] = []
            func record(_ stage: String, _ detail: String) {
                let event = EjectionEvent(diskID: disk.id, stage: stage, detail: detail)
                events.append(event); progress(event)
            }
            record("eject", "Ejecting \(disk.name)")
            var attempt = await eject(disk)
            var error = attempt.error
            var diagnosis: BlockerReport?
            var saveFailures: Set<String> = []
            var mayQuit: Set<String> = []
            var closed: Set<String> = []
            var quit: Set<String> = []
            var actions = 0
            var vanishedHolders = 0
            // Always try normal ejection first. Each escalation is scoped to
            // freshly confirmed holders. New holders start at document release,
            // even if a previous holder already reached the quit stage.
            while error != nil && attempt.isBusy && actions < 64 && vanishedHolders < 8 {
                guard !Task.isCancelled else { error = "Ejection cancelled"; break }
                let report = await inspect(disk)
                diagnosis = report
                record("diagnose", report.blockers.isEmpty ? "No inspectable process holder found" : "Found \(report.blockers.count) process holder(s)")
                guard !Task.isCancelled else { error = "Ejection cancelled"; break }
                let candidate = report.blockers.first { !closed.contains($0.id) && !saveFailures.contains($0.id) }
                    ?? report.blockers.first { mayQuit.contains($0.id) && !quit.contains($0.id) && !saveFailures.contains($0.id) }
                guard let blocker = candidate else {
                    // References may have disappeared independently since the
                    // last attempt. Give normal ejection the final say.
                    attempt = await eject(disk)
                    error = attempt.error
                    break
                }
                let level: ReleaseLevel = closed.contains(blocker.id) ? .quitBlockingApp : .closeDocuments
                let fresh = await inspect(disk)
                guard !Task.isCancelled else { error = "Ejection cancelled"; break }
                if let current = fresh.blockers.first(where: {
                    $0.id == blocker.id && $0.executable == blocker.executable
                }) {
                    record(level.rawValue, "\(current.name) (PID \(current.pid))")
                    let outcome = await release(disk, current, level)
                    record(outcome.succeeded ? "released" : "releaseFailed", "\(current.name) (PID \(current.pid)): \(outcome.detail)")
                    actions += 1
                    if level == .closeDocuments { closed.insert(blocker.id) }
                    else { quit.insert(blocker.id) }
                    if !outcome.succeeded && !outcome.mayEscalate { saveFailures.insert(blocker.id) }
                    if level == .closeDocuments && (outcome.succeeded || outcome.mayEscalate) { mayQuit.insert(blocker.id) }
                } else { vanishedHolders += 1 }
                guard !Task.isCancelled else { error = "Ejection cancelled"; break }
                // Reattempt after every action or disappeared holder. Stop
                // touching applications as soon as the disk can eject.
                attempt = await eject(disk)
                error = attempt.error
            }
            if error != nil && (actions >= 64 || vanishedHolders >= 8) {
                record("releaseFailed", "Disk references kept changing; bounded recovery stopped with the disk still attached")
            }
            if error == nil {
                record("verify", "Checking that the original disk attachment disappeared")
                if !(await verify(disk)) { error = "macOS accepted ejection, but the disk is still present" }
            }
            if error != nil, !Task.isCancelled { diagnosis = await inspect(disk) }
            record(error == nil ? "complete" : "blocked", error ?? "Safely ejected")
            results.append(.init(disk: disk, succeeded: error == nil, error: error, diagnosis: diagnosis, events: events))
        }
        return results
    }
}

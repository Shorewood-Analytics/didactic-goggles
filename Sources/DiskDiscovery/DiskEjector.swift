import Foundation
import IOKit
import DiskArbitration

public struct EjectionResult: Equatable, Sendable {
    public let disk: Disk
    public let error: String?
    public var succeeded: Bool { error == nil }
}

private struct ArbitrationFailure {
    let code: DAReturn
    let message: String
}
private final class ArbitrationReply {
    let continuation: CheckedContinuation<ArbitrationFailure?, Never>
    init(_ continuation: CheckedContinuation<ArbitrationFailure?, Never>) { self.continuation = continuation }
}

private let arbitrationCallback: DADiskUnmountCallback = { _, dissenter, context in
    guard let context else { return }
    let reply = Unmanaged<ArbitrationReply>.fromOpaque(context).takeRetainedValue()
    let message = dissenter.map {
        ArbitrationFailure(code: DADissenterGetStatus($0),
                           message: (DADissenterGetStatusString($0) as String?)
                             ?? "macOS refused the operation (\(DADissenterGetStatus($0))).")
    }
    reply.continuation.resume(returning: message)
}

/// Ejects a captured set of whole physical disks, with no force-unmount fallback.
/// Keeps Disk Arbitration references tied to their original registry identities.
@MainActor
public final class DiskEjector {
    public private(set) var isEjecting = false
    private let eligibleDisks: () throws -> [Disk]
    public convenience init() { self.init(eligibleDisks: { try IOKitDiskSource().snapshot() }) }
    package init(eligibleDisks: @escaping () throws -> [Disk]) { self.eligibleDisks = eligibleDisks }

    public func ejectAll(_ disks: [Disk], progress: (Int, Int) -> Void = { _, _ in }) async -> [EjectionResult] {
        guard !isEjecting else {
            return disks.map { EjectionResult(disk: $0, error: "An ejection is already in progress.") }
        }
        isEjecting = true
        defer { isEjecting = false }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return disks.map { EjectionResult(disk: $0, error: "Disk Arbitration is unavailable.") }
        }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        defer { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
        var results: [EjectionResult] = []
        var seen: Set<UInt64> = []
        let targets = disks.filter { seen.insert($0.id).inserted }
        for (index, disk) in targets.enumerated() {
            progress(index + 1, targets.count)
            guard let current = try? eligibleDisks(),
                  current.contains(where: { $0.id == disk.id && $0.bsdName == disk.bsdName }) else {
                results.append(EjectionResult(disk: disk, error: "Disk is no longer an eligible external disk or SD card."))
                continue
            }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(disk.id))
            guard service != 0 else {
                results.append(EjectionResult(disk: disk, error: "Disk disconnected before ejection."))
                continue
            }
            let native = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, service)
            IOObjectRelease(service)
            guard let native, let name = DADiskGetBSDName(native), String(cString: name) == disk.bsdName else {
                results.append(EjectionResult(disk: disk, error: "Disk identity changed; ejection skipped."))
                continue
            }
            let layout = MediaLayout.read(disk)
            let systemMounts = MountedSpace.snapshot().filter { $0.path == "/" || $0.path == "/System/Volumes/Data" }
            guard !layout.isEmpty, !layout.contains(where: \.ambiguous),
                  !systemMounts.contains(where: { mount in layout.contains {
                      mount.bsdName == $0.bsdName || mount.bsdName.hasPrefix($0.bsdName + "s")
                  } }) else {
                results.append(EjectionResult(disk: disk, error: "System disk or ambiguous storage layout; ejection skipped."))
                continue
            }
            // APFS synthesized containers are separate whole media. Unmount
            // their volumes first, then the physical disk's ordinary partitions.
            var unmountFailure: String?
            for branch in layout.filter(\.whole).sorted(by: { $0.depth > $1.depth }) {
                let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(branch.id))
                guard service != 0 else { unmountFailure = "Disk disconnected during unmount."; break }
                let target = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, service)
                IOObjectRelease(service)
                guard let target else { unmountFailure = "Volume information is unavailable."; break }
                let error = await withCheckedContinuation { continuation in
                    let context = Unmanaged.passRetained(ArbitrationReply(continuation)).toOpaque()
                    DADiskUnmount(target, DADiskUnmountOptions(kDADiskUnmountOptionWhole), arbitrationCallback, context)
                }
                if let error, error.code != kDAReturnNotMounted { unmountFailure = error.message; break }
            }
            if let unmountFailure {
                results.append(EjectionResult(disk: disk, error: "Unmount failed: \(unmountFailure)"))
                continue
            }
            guard let current = try? eligibleDisks(),
                  current.contains(where: { $0.id == disk.id && $0.bsdName == disk.bsdName }) else {
                results.append(EjectionResult(disk: disk, error: "Disk disconnected during unmount; eject skipped."))
                continue
            }
            let ejectError = await withCheckedContinuation { continuation in
                let context = Unmanaged.passRetained(ArbitrationReply(continuation)).toOpaque()
                DADiskEject(native, DADiskEjectOptions(kDADiskEjectOptionDefault), arbitrationCallback, context)
            }
            results.append(EjectionResult(disk: disk, error: ejectError.map { "Eject failed: \($0.message)" }))
        }
        return results
    }
}

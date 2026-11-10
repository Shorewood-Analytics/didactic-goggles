import Foundation
import Darwin

public struct DiskUsage: Codable, Equatable, Sendable {
    /// Capacity of the formatted storage pools; excludes partition tables and
    /// unallocated space. Physical media capacity remains Disk.sizeBytes.
    public let totalBytes: UInt64?
    public let freeBytes: UInt64?
    public let unavailableReason: String?
    public let sampledAt: Date
    public var usedBytes: UInt64? {
        guard let totalBytes, let freeBytes, freeBytes <= totalBytes else { return nil }
        return totalBytes - freeBytes
    }
    public var percentUsed: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
    public init(totalBytes: UInt64?, freeBytes: UInt64?, unavailableReason: String? = nil,
                sampledAt: Date = Date()) {
        self.totalBytes = totalBytes; self.freeBytes = freeBytes
        self.unavailableReason = unavailableReason; self.sampledAt = sampledAt
    }
    static func unavailable(_ reason: String) -> DiskUsage {
        DiskUsage(totalBytes: nil, freeBytes: nil, unavailableReason: reason)
    }
}

/// Reads registry topology and cached filesystem counters off the main thread.
/// Works in the app sandbox without shell commands or file-content permission.
public final class DiskUsageReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DiskDiscovery.usage", qos: .utility)
    public init() {}

    public func read(_ disks: [Disk]) async -> [UInt64: DiskUsage] {
        guard !disks.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            queue.async {
                let mounted = MountedSpace.snapshot()
                var result: [UInt64: DiskUsage] = [:]
                for disk in disks {
                    result[disk.id] = UsageResolver.resolve(root: disk.id, nodes: MediaLayout.read(disk), mounted: mounted)
                }
                continuation.resume(returning: result)
            }
        }
    }
}

enum UsageResolver {
    static func resolve(root: UInt64, nodes: [MediaNode], mounted: [MountedSpace]) -> DiskUsage {
        guard !nodes.isEmpty, !nodes.contains(where: \.ambiguous) else {
            return .unavailable("Disk topology is unavailable or spans multiple devices")
        }
        let systemContent = ["EFI", "APPLE_BOOT", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",
                             "426F6F74-0000-11AA-AA11-00306543ECAC"]
        let leaves = nodes.filter { $0.leaf && !systemContent.contains($0.content.uppercased()) }
        guard !leaves.isEmpty else { return .unavailable("No readable formatted storage") }
        // An APFS synthesized whole medium identifies the shared pool. Ordinary
        // partitions each have their own filesystem and must be added separately.
        let groups = Dictionary(grouping: leaves) { node in
            node.wholeAncestor.flatMap { $0 == root ? nil : $0 } ?? node.id
        }
        var total: UInt64 = 0, free: UInt64 = 0
        for (group, members) in groups {
            let samples = mounted.filter { space in members.contains { $0.bsdName == space.bsdName } }
            guard let sample = samples.first else {
                return .unavailable("Usage incomplete: a volume is unmounted, locked, or not reported")
            }
            if !members.contains(where: { $0.id == group }) {
                // Don't assume that an arbitrary synthesized medium shares space.
                guard samples.allSatisfy({ $0.filesystem == "apfs" && $0.total == sample.total && $0.free == sample.free }) else {
                    return .unavailable("Shared-pool capacity is inconsistent or quota-limited")
                }
            }
            guard sample.total > 0, sample.free <= sample.total else {
                return .unavailable("Invalid capacity values")
            }
            let sum = total.addingReportingOverflow(sample.total)
            let freeSum = free.addingReportingOverflow(sample.free)
            guard !sum.overflow, !freeSum.overflow else { return .unavailable("Invalid capacity values") }
            total = sum.partialValue; free = freeSum.partialValue
        }
        return DiskUsage(totalBytes: total, freeBytes: free)
    }
}

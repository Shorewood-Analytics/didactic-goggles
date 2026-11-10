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

/// Read-only diskutil queries run serially off the main thread, with bounded
/// child lifetimes. No shell, privilege escalation, mounting, or filesystem scan.
public final class DiskUsageReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DiskDiscovery.usage", qos: .utility)
    public init() {}

    public func read(_ disks: [Disk]) async -> [UInt64: DiskUsage] {
        guard !disks.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let list = try Diskutil.read(["list", "-plist", "physical"])
                    let apfs = try? Diskutil.read(["apfs", "list", "-plist"])
                    var results: [UInt64: DiskUsage] = [:]
                    for disk in disks {
                        let items = UsageResolver.partitions(for: disk.bsdName, list: list)
                        var info: [String: [String: Any]] = [:]
                        for item in items where !UsageResolver.isAPFS(item) && !UsageResolver.isSystem(item) {
                            if let name = item["DeviceIdentifier"] as? String {
                                info[name] = try? Diskutil.read(["info", "-plist", name])
                            }
                        }
                        results[disk.id] = UsageResolver.resolve(disk: disk.bsdName, list: list,
                                                                 apfs: apfs, info: info)
                    }
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(returning: Dictionary(uniqueKeysWithValues: disks.map {
                        ($0.id, DiskUsage.unavailable("Usage not available: \(error.localizedDescription)"))
                    }))
                }
            }
        }
    }
}

enum Diskutil {
    static func read(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The timer is canceled before this Process can leave scope. kill targets
        // only this live child; termination reaping happens after timer cancellation.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 8)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        timer.cancel()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DiskDiscovery", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "macOS did not provide disk capacity"])
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "DiskDiscovery", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unrecognized disk information"])
        }
        return plist
    }
}

enum UsageResolver {
    static func partitions(for disk: String, list: [String: Any]) -> [[String: Any]] {
        guard let roots = list["AllDisksAndPartitions"] as? [[String: Any]],
              let root = roots.first(where: { $0["DeviceIdentifier"] as? String == disk }) else { return [] }
        let partitions = root["Partitions"] as? [[String: Any]] ?? []
        return partitions.isEmpty ? [root] : partitions
    }
    static func isAPFS(_ item: [String: Any]) -> Bool {
        item["Content"] as? String == "Apple_APFS" || item["APFSContainerReference"] != nil
    }
    static func isSystem(_ item: [String: Any]) -> Bool {
        ["EFI", "Apple_Boot"].contains(item["Content"] as? String ?? "")
    }
    static func resolve(disk: String, list: [String: Any], apfs: [String: Any]?,
                        info: [String: [String: Any]]) -> DiskUsage {
        let items = partitions(for: disk, list: list).filter { !isSystem($0) }
        guard !items.isEmpty else { return .unavailable("No readable formatted storage") }
        var countedContainers: Set<String> = []
        var total: UInt64 = 0, free: UInt64 = 0
        let identifiers = Set(items.compactMap { $0["DeviceIdentifier"] as? String })
        for item in items {
            guard let identifier = item["DeviceIdentifier"] as? String else {
                return .unavailable("Incomplete partition information")
            }
            let capacity: UInt64?, available: UInt64?
            if isAPFS(item) {
                guard let containers = apfs?["Containers"] as? [[String: Any]],
                      let container = containers.first(where: {
                          ($0["PhysicalStores"] as? [[String: Any]] ?? []).contains {
                              $0["DeviceIdentifier"] as? String == identifier
                          }
                      }), let reference = container["ContainerReference"] as? String,
                      let stores = container["PhysicalStores"] as? [[String: Any]], !stores.isEmpty else {
                    return .unavailable("APFS container usage not reported")
                }
                guard stores.allSatisfy({ identifiers.contains($0["DeviceIdentifier"] as? String ?? "") }) else {
                    return .unavailable("APFS storage spans multiple disks")
                }
                guard countedContainers.insert(reference).inserted else { continue }
                capacity = unsigned(container["CapacityCeiling"])
                available = unsigned(container["CapacityFree"])
            } else {
                capacity = unsigned(info[identifier]?["VolumeTotalSpace"])
                available = unsigned(info[identifier]?["VolumeFreeSpace"])
            }
            guard let capacity, let available, capacity > 0, available <= capacity else {
                return .unavailable("Usage incomplete: a volume is unmounted, locked, or not reported")
            }
            let sum = total.addingReportingOverflow(capacity)
            let freeSum = free.addingReportingOverflow(available)
            guard !sum.overflow, !freeSum.overflow else { return .unavailable("Invalid capacity values") }
            total = sum.partialValue; free = freeSum.partialValue
        }
        guard total > 0 else { return .unavailable("No readable formatted storage") }
        return DiskUsage(totalBytes: total, freeBytes: free)
    }
    static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.doubleValue >= 0 else { return nil }
        return number.uint64Value
    }
}

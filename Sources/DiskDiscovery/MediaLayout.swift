import Foundation
import IOKit
import Darwin

struct MediaNode {
    let id: UInt64
    let bsdName: String
    let whole: Bool
    let leaf: Bool
    let content: String
    /// Closest containing whole medium, including APFS synthesized containers.
    let wholeAncestor: UInt64?
    let depth: Int
    let ambiguous: Bool
}

/// Follows the actual registry graph instead of guessing relationships from
/// BSD-number prefixes. APFS volumes live beneath a synthesized whole medium.
enum MediaLayout {
    static func read(_ disk: Disk) -> [MediaNode] {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(disk.id))
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        guard let first = node(root), first.whole, first.bsdName == disk.bsdName else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = [first]
        var seen: Set<UInt64> = [first.id]
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, "IOMedia") != 0 else { continue }
            // A disappearing or unreadable medium must not silently drop out of
            // an otherwise successful capacity/ejection topology snapshot.
            guard let item = node(entry) else { return [] }
            if seen.insert(item.id).inserted { result.append(item) }
        }
        // Registry changes can invalidate a recursive iterator before it has
        // returned every volume. Reject that partial inventory and retry on the
        // next refresh instead of treating it as the complete disk layout.
        return IOIteratorIsValid(iterator) != 0 ? result : []
    }

    private static func node(_ entry: io_registry_entry_t) -> MediaNode? {
        guard IOObjectConformsTo(entry, "IOMedia") != 0 else { return nil }
        var props: Unmanaged<CFMutableDictionary>?
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
              IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = props?.takeRetainedValue() as? [String: Any],
              let name = values["BSD Name"] as? String else { return nil }
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        var depth = 0
        var wholeAncestor: UInt64?
        var ambiguous = false
        while depth < 128 {
            var parents: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(current, kIOServicePlane, &parents) == KERN_SUCCESS else { break }
            let parent = IOIteratorNext(parents)
            let second = IOIteratorNext(parents)
            if second != 0 { ambiguous = true; IOObjectRelease(second) }
            IOObjectRelease(parents)
            guard parent != 0 else { break }
            IOObjectRelease(current)
            current = parent
            depth += 1
            if wholeAncestor == nil, IOObjectConformsTo(current, "IOMedia") != 0,
               (IORegistryEntryCreateCFProperty(current, "Whole" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool) == true {
                var ancestorID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(current, &ancestorID) == KERN_SUCCESS {
                    wholeAncestor = ancestorID
                }
            }
        }
        return MediaNode(id: id, bsdName: name, whole: values["Whole"] as? Bool == true,
                         leaf: values["Leaf"] as? Bool == true, content: values["Content"] as? String ?? "",
                         wholeAncestor: wholeAncestor, depth: depth, ambiguous: ambiguous || depth == 128)
    }
}

struct MountedSpace {
    let bsdName: String
    let path: String
    let filesystem: String
    let total: UInt64
    let free: UInt64

    /// Cached filesystem counters supplied by the kernel. Does not enumerate
    /// files, execute diskutil, or require access to a volume's contents.
    static func snapshot() -> [MountedSpace] {
        let expected = getfsstat(nil, 0, MNT_NOWAIT)
        guard expected > 0 else { return [] }
        var entries: [statfs] = .init(repeating: .init(), count: Int(expected) + 16)
        let count = entries.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard count > 0 else { return [] }
        return entries.prefix(Int(count)).compactMap { original -> MountedSpace? in
            var entry = original
            let device = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard device.hasPrefix("/dev/") else { return nil }
            let path = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let filesystem = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let total = entry.f_blocks.multipliedReportingOverflow(by: UInt64(entry.f_bsize))
            let free = entry.f_bfree.multipliedReportingOverflow(by: UInt64(entry.f_bsize))
            guard !total.overflow, !free.overflow else { return nil }
            return MountedSpace(bsdName: String(device.dropFirst(5)), path: path, filesystem: filesystem,
                                total: total.partialValue, free: free.partialValue)
        }
    }
}

import Foundation
import IOKit

public enum DiskPresence: Equatable, Sendable { case present, gone, unknown }

public struct MountedDiskVolume: Codable, Equatable, Sendable {
    public let bsdName: String
    public let path: String
}

public struct DiskInspection: Sendable {
    public let volumes: [MountedDiskVolume]
    public let devicePaths: [String]
    public let presence: DiskPresence
    public var present: Bool { presence != .gone }

    public static func presence(of disk: Disk) -> DiskPresence {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IORegistryEntryIDMatching(disk.id), &iterator)
                == KERN_SUCCESS else { return .unknown }
        defer { IOObjectRelease(iterator) }
        let media = IOIteratorNext(iterator)
        guard media != 0 else { return .gone }
        IOObjectRelease(media)
        return .present
    }

    public static func read(_ disk: Disk) -> DiskInspection {
        let layout = MediaLayout.read(disk)
        let names = Set(layout.map(\.bsdName))
        return DiskInspection(volumes: MountedSpace.snapshot().filter { names.contains($0.bsdName) }
            .map { .init(bsdName: $0.bsdName, path: $0.path) },
            devicePaths: names.sorted().flatMap { ["/dev/" + $0, "/dev/r" + $0] }, presence: presence(of: disk))
    }
}

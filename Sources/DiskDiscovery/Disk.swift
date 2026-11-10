import Foundation

/// A physical whole medium, independent of its partitions or mounted volumes.
public struct Disk: Codable, Equatable, Identifiable, Sendable {
    public enum Connection: String, Codable, Sendable {
        case external
        case builtInSDReader
    }

    /// I/O Registry identity for this attachment; not a persistent hardware ID.
    public let id: UInt64
    public let bsdName: String
    public let name: String
    public let sizeBytes: UInt64
    public let transport: String
    public let connection: Connection
}

/// Registry facts, kept separate from the selection policy for fixture testing.
struct MediaFacts {
    var id: UInt64
    var bsdName: String?
    var name: String?
    var sizeBytes: UInt64
    var isWhole: Bool
    var hasPhysicalDevice: Bool
    var hasMediaAncestor: Bool
    var transport: String?
    var location: String?

    func selectedDisk() -> Disk? {
        guard isWhole, hasPhysicalDevice, !hasMediaAncestor, sizeBytes > 0,
              let bsdName, !bsdName.isEmpty,
              let transport, !transport.isEmpty,
              transport != "Virtual Interface" else { return nil }

        let connection: Disk.Connection
        if location == "External" {
            connection = .external
        } else if location == "Internal", transport == "Secure Digital" {
            connection = .builtInSDReader
        } else {
            // Do not turn missing/ambiguous metadata into an external disk.
            return nil
        }

        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Disk(
            id: id, bsdName: bsdName,
            name: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? bsdName,
            sizeBytes: sizeBytes, transport: transport, connection: connection
        )
    }
}

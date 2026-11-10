import Foundation

/// A registry-reported link, not a measured file-transfer rate or port maximum.
public struct DetectedLink: Codable, Equatable, Sendable {
    public let kind: String
    public let value: String
    public let source: String

    public init(kind: String, value: String, source: String) {
        self.kind = kind; self.value = value; self.source = source
    }
}

enum LinkDecoder {
    static func usb(_ code: Int, host: Bool) -> DetectedLink? {
        // IOUSBHost uses the xHCI speed IDs. Legacy IOUSBDevice uses the
        // DIFFERENT USBDeviceSpeed enumeration; never interchange the two.
        let hostSpeeds = [1: "12 Mb/s", 2: "1.5 Mb/s", 3: "480 Mb/s",
                          4: "5 Gb/s", 5: "10 Gb/s", 6: "20 Gb/s"]
        let legacySpeeds = [0: "1.5 Mb/s", 1: "12 Mb/s", 2: "480 Mb/s",
                            3: "5 Gb/s", 4: "10 Gb/s", 5: "20 Gb/s"]
        guard let value = (host ? hostSpeeds : legacySpeeds)[code] else { return nil }
        return DetectedLink(kind: "USB link", value: value,
                            source: host ? "IOUSBHostDevice.USBSpeed" : "IOUSBDevice.Device Speed")
    }

    static func pci(_ status: UInt32) -> DetectedLink? {
        let rates: [UInt32: String] = [1: "2.5", 2: "5", 3: "8", 4: "16", 5: "32", 6: "64"]
        let lanes = (status >> 4) & 0x3f
        guard let rate = rates[status & 0xf], [1, 2, 4, 8, 12, 16, 32].contains(lanes) else { return nil }
        return DetectedLink(kind: "PCIe device link", value: "\(rate) GT/s × \(lanes)",
                            source: "IOPCIDevice.IOPCIExpressLinkStatus")
    }

    static func port(_ properties: [String: Any]) -> DetectedLink? {
        guard let controller = properties["Controller Characteristics"] as? [String: Any],
              let speed = controller["Port Speed"] as? String,
              speed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        return DetectedLink(kind: "Storage port", value: speed,
                            source: "Controller Characteristics.Port Speed")
    }

    static func cardType(_ properties: [String: Any]) -> String? {
        guard let card = properties["Card Characteristics"] as? [String: Any],
              let type = card["Card Type"] as? String else { return nil }
        let result = type.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

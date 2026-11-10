import Foundation
import IOKit

private struct RegistryError: LocalizedError {
    let operation: String
    let code: kern_return_t

    var errorDescription: String? {
        "\(operation) failed (IOKit \(code))."
    }
}

private func wholeMediaMatching() throws -> CFMutableDictionary {
    guard let dictionary = IOServiceMatching("IOMedia") else {
        throw RegistryError(operation: "Create media match", code: KERN_FAILURE)
    }
    let mutable = dictionary as NSMutableDictionary
    mutable["Whole"] = true
    return dictionary
}

private func drain(_ iterator: io_iterator_t) {
    while true {
        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else { return }
        IOObjectRelease(service)
    }
}

private final class CallbackContext {
    let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }
}

/// Owns all native handles. A separately retained callback context stays alive
/// until main-thread cleanup, even if the last Swift owner is released elsewhere.
private final class Registration {
    var port: IONotificationPortRef?
    var source: CFRunLoopSource?
    var matched: io_iterator_t = 0
    var terminated: io_iterator_t = 0
    let context: UnsafeMutableRawPointer

    init(onChange: @escaping @MainActor () -> Void) {
        context = Unmanaged.passRetained(CallbackContext(onChange: onChange)).toOpaque()
    }

    deinit {
        let port = port, source = source, matched = matched, terminated = terminated, context = context
        let cleanup = {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if matched != 0 { IOObjectRelease(matched) }
            if terminated != 0 { IOObjectRelease(terminated) }
            if let port { IONotificationPortDestroy(port) }
            Unmanaged<CallbackContext>.fromOpaque(context).release()
        }
        if Thread.isMainThread { cleanup() }
        else { DispatchQueue.main.async(execute: cleanup) }
    }
}

private let registryChanged: IOServiceMatchingCallback = { context, iterator in
    // Empty every iterator, even when no candidate disk is selected. This arms
    // the next notification and releases each returned service reference.
    drain(iterator)
    guard let context else { return }
    MainActor.assumeIsolated {
        let callback = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        callback.onChange()
    }
}

@MainActor
final class IOKitDiskSource: DiskSource {
    private var registration: Registration?

    func start(onChange: @escaping @MainActor () -> Void) throws {
        guard registration == nil else { return }
        let next = Registration(onChange: onChange)
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw RegistryError(operation: "Create notification port", code: KERN_FAILURE)
        }
        next.port = port
        let context = next.context

        // Each registration consumes its matching dictionary: use a fresh one.
        var result = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, try wholeMediaMatching(),
            registryChanged, context, &next.matched
        )
        guard result == KERN_SUCCESS else {
            throw RegistryError(operation: "Watch media arrival", code: result)
        }
        drain(next.matched)

        result = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, try wholeMediaMatching(),
            registryChanged, context, &next.terminated
        )
        guard result == KERN_SUCCESS else {
            throw RegistryError(operation: "Watch media removal", code: result)
        }
        drain(next.terminated)

        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw RegistryError(operation: "Create notification source", code: KERN_FAILURE)
        }
        next.source = source
        registration = next
        // Common modes keep notifications flowing while an NSMenu is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        registration = nil
    }

    func snapshot() throws -> [Disk] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault, try wholeMediaMatching(), &iterator
        )
        guard result == KERN_SUCCESS else {
            throw RegistryError(operation: "Enumerate media", code: result)
        }
        defer { IOObjectRelease(iterator) }

        var disks: [UInt64: Disk] = [:]
        while true {
            let media = IOIteratorNext(iterator)
            guard media != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(media) }
            if let disk = readMedia(media) { disks[disk.id] = disk }
        }
        return Array(disks.values)
    }

    private func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var values: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &values, kCFAllocatorDefault, 0)
                == KERN_SUCCESS else { return nil }
        return values?.takeRetainedValue() as? [String: Any]
    }

    private func readMedia(_ media: io_registry_entry_t) -> Disk? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS,
              let values = properties(media) else { return nil }

        var facts = MediaFacts(
            id: id, bsdName: values["BSD Name"] as? String,
            name: nil, sizeBytes: (values["Size"] as? NSNumber)?.uint64Value ?? 0,
            isWhole: (values["Whole"] as? Bool) == true,
            hasPhysicalDevice: false, hasMediaAncestor: false,
            transport: nil, location: nil
        )

        // Inspect the nearest physical storage device. A partition/container
        // with an intervening IOMedia ancestor must not duplicate its disk.
        var link: DetectedLink?
        var cardType = LinkDecoder.cardType(values)
        var sawUSBDevice = false
        var sawPCIDevice = false
        var entry = media
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
                    == KERN_SUCCESS else { break }
            IOObjectRelease(entry)
            entry = parent
            if !facts.hasPhysicalDevice, IOObjectConformsTo(entry, "IOMedia") != 0 {
                facts.hasMediaAncestor = true
                break
            }
            let device = properties(entry) ?? [:]
            cardType = cardType ?? LinkDecoder.cardType(device)
            if !facts.hasPhysicalDevice, IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                facts.hasPhysicalDevice = true
                let protocolInfo = device["Protocol Characteristics"] as? [String: Any]
                facts.transport = protocolInfo?["Physical Interconnect"] as? String
                facts.location = protocolInfo?["Physical Interconnect Location"] as? String
                let characteristics = device["Device Characteristics"] as? [String: Any]
                facts.name = characteristics?["Product Name"] as? String
                link = LinkDecoder.port(device)
            }
            // Stop at the first USB device: a faster parent hub is not this disk's link.
            if facts.transport == "USB", !sawUSBDevice {
                let host = IOObjectConformsTo(entry, "IOUSBHostDevice") != 0
                let legacy = IOObjectConformsTo(entry, "IOUSBDevice") != 0
                if host || legacy {
                    sawUSBDevice = true
                    if let speed = device[host ? "USBSpeed" : "Device Speed"] as? NSNumber {
                        link = LinkDecoder.usb(speed.intValue, host: host) ?? link
                    }
                    break
                }
            }
            // The endpoint's PCIe link is not the Thunderbolt cable's link rate.
            if facts.transport == "PCI-Express", !sawPCIDevice,
               IOObjectConformsTo(entry, "IOPCIDevice") != 0 {
                sawPCIDevice = true
                if let status = device["IOPCIExpressLinkStatus"] as? NSNumber {
                    link = LinkDecoder.pci(status.uint32Value) ?? link
                }
                break
            }
            if facts.hasPhysicalDevice, link == nil { link = LinkDecoder.port(device) }
        }
        guard var disk = facts.selectedDisk() else { return nil }
        disk.link = link
        disk.cardType = cardType
        return disk
    }
}

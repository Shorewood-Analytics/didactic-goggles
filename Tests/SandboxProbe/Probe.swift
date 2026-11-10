import Foundation
import IOKit
import DiskDiscovery

/// CI-only executable; never included in DiskWatch.app. The harness supplies
/// only its newly created disposable image, allowing real sandbox validation.
@main
struct SandboxProbe {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let name = CommandLine.arguments[1]
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
        guard media != 0 else { exit(3) }
        var id: UInt64 = 0
        let status = IORegistryEntryGetRegistryEntryID(media, &id)
        IOObjectRelease(media)
        guard status == KERN_SUCCESS else { exit(4) }
        let disk = Disk(id: id, bsdName: name, name: "Sandbox test image", sizeBytes: 128_000_000,
                        transport: "Virtual Interface", connection: .external)
        var finished = false
        Task {
            let usage = await DiskUsageReader().read([disk])
            guard let percent = usage[id]?.percentUsed else {
                print("Sandbox capacity failed:", usage[id] as Any)
                exit(5)
            }
            print("Sandbox capacity:", percent)
            let results = await DiskEjector(eligibleDisks: { [disk] }).ejectAll([disk])
            guard results.count == 1, results[0].succeeded else {
                print("Sandbox eject failed:", results)
                exit(6)
            }
            print("Sandbox capacity and ejection succeeded.")
            finished = true
        }
        let deadline = Date().addingTimeInterval(45)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard finished else { exit(7) }
    }
}

import Foundation
import DiskDiscovery

@MainActor
public final class MacEjectionService {
    public let coordinator: EjectionCoordinator
    public init() {
        let ejector = DiskEjector()
        let inspector = ProcessBlockerInspector()
        let releaser = ApplicationReleaser()
        let lease = EjectionLease()
        coordinator = EjectionCoordinator(eject: { disk in
            guard let result = await ejector.ejectAll([disk]).first else {
                return .init(error: "No ejection result")
            }
            return .init(error: result.error, isBusy: result.isBusy)
        }, inspect: { disk in
            await inspector.inspect(disk)
        }, release: { disk, blocker, level in
            await releaser.release(disk, blocker: blocker, level: level)
        }, verify: { disk in
            for _ in 0..<30 {
                if DiskInspection.presence(of: disk) == .gone { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }, begin: { lease.acquire() }, end: { lease.release() })
    }
}

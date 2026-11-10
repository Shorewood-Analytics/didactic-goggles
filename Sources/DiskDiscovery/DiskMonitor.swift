import Foundation

@MainActor
protocol DiskSource: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void) throws
    func snapshot() throws -> [Disk]
    func stop()
}

/// A long-lived, event-driven monitor. Requires the main run loop to be serviced.
/// Has no AppKit/SwiftUI dependency and does not open, mount, or modify media.
@MainActor
public final class DiskMonitor {
    public private(set) var disks: [Disk] = []
    public private(set) var isRunning = false
    /// A failed refresh preserves the last snapshot and exposes that it is stale.
    public private(set) var lastError: String?
    /// Called on the main actor after startup, changes, errors, or explicit stop.
    public var onChange: (@MainActor () -> Void)?

    private let source: DiskSource
    private var generation: UInt64 = 0

    public convenience init() {
        self.init(source: IOKitDiskSource())
    }

    init(source: DiskSource) {
        self.source = source
    }

    public func start() throws {
        guard !isRunning else { return }
        generation &+= 1
        let expectedGeneration = generation
        do {
            try source.start { [weak self] in
                guard let self, self.isRunning,
                      self.generation == expectedGeneration else { return }
                self.reload()
            }
            disks = sorted(try source.snapshot())
            lastError = nil
            isRunning = true
            onChange?()
        } catch {
            source.stop()
            lastError = error.localizedDescription
            onChange?()
            throw error
        }
    }

    public func stop() {
        generation &+= 1
        source.stop()
        isRunning = false
        disks = []
        lastError = nil
        onChange?()
    }

    /// Optional reconciliation, for example after system wake. No polling timer.
    public func refresh() {
        guard isRunning else { return }
        reload()
    }

    private func reload() {
        do {
            let next = sorted(try source.snapshot())
            let changed = next != disks || lastError != nil
            disks = next
            lastError = nil
            if changed { onChange?() }
        } catch {
            lastError = error.localizedDescription
            onChange?()
        }
    }

    private func sorted(_ disks: [Disk]) -> [Disk] {
        disks.sorted { $0.id < $1.id }
    }
}

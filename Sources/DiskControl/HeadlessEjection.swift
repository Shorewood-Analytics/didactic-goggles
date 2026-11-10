import Foundation
import DiskDiscovery

public enum HeadlessCommand: String { case ejectAll, diagnose }

/// No window or UI event handler is required. JSON result on stdout, JSON
/// progress on stderr, and a nonzero exit status until every target is verified.
public enum HeadlessEjection {
    @MainActor
    public static func run(_ command: HeadlessCommand) -> Int32 {
        let monitor = DiskMonitor()
        do { try monitor.start() }
        catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
        defer { monitor.stop() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var resultCode: Int32?
        Task {
            do {
                let data: Data
                if command == .diagnose {
                    let inspector = ProcessBlockerInspector()
                    var reports: [String: BlockerReport] = [:]
                    for disk in monitor.disks { reports[disk.bsdName] = await inspector.inspect(disk) }
                    data = try encoder.encode(reports)
                    resultCode = 0
                } else {
                    let results = await MacEjectionService().coordinator.ejectAll(monitor.disks) { event in
                        if var data = try? encoder.encode(event) {
                            data.append(10); try? FileHandle.standardError.write(contentsOf: data)
                        }
                    }
                    data = try encoder.encode(results)
                    resultCode = results.allSatisfy(\.succeeded) ? 0 : 1
                }
                var output = data; output.append(10)
                try FileHandle.standardOutput.write(contentsOf: output)
            } catch { fputs("\(error.localizedDescription)\n", stderr); resultCode = 1 }
        }
        while resultCode == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return resultCode ?? 1
    }
}

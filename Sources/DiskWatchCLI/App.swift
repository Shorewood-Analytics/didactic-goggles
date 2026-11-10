import Foundation
import DiskDiscovery
import DiskControl
import Darwin

@main
struct DiskWatchCLI {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["eject-all"] { exit(HeadlessEjection.run(.ejectAll)) }
        if arguments == ["diagnose"] { exit(HeadlessEjection.run(.diagnose)) }
        let usage = "Usage: disk-watch [--once | eject-all | diagnose]\nWithout arguments, writes JSON snapshots until interrupted.\nEjection may save and close documents on busy disks and quit the blocking app."
        if arguments == ["--help"] { print(usage); return }
        guard arguments.isEmpty || arguments == ["--once"] else {
            fputs("\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let monitor = DiskMonitor()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        monitor.onChange = {
            if let error = monitor.lastError {
                fputs("Disk snapshot unavailable: \(error)\n", stderr)
                return
            }
            guard monitor.isRunning else { return }
            do {
                var data = try encoder.encode(monitor.disks)
                data.append(0x0a)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                fputs("Cannot write snapshot: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        do {
            try monitor.start()
        } catch {
            exit(EXIT_FAILURE)
        }
        if arguments == ["--once"] {
            monitor.stop()
            monitor.onChange = nil
            return
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                monitor.stop()
                monitor.onChange = nil
                CFRunLoopStop(CFRunLoopGetMain())
            }
            source.resume()
            return source
        }
        withExtendedLifetime(signals) { CFRunLoopRun() }
        signals.forEach { $0.cancel() }
    }
}

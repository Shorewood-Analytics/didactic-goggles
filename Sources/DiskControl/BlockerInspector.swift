import Foundation
import Darwin
import DiskDiscovery

/// Process inspection uses macOS libproc, the same volume-reference query used
/// by diskarbitrationd. This backend is for the direct-distribution app/CLI.
public final class ProcessBlockerInspector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DiskWatch.blockers", qos: .utility)
    public init() {}
    public func inspect(_ disk: Disk) async -> BlockerReport {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.scan(disk)) }
        }
    }

    static func identity(_ pid: Int32, paths: [String] = []) -> DiskBlocker? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { return nil }
        let path = String(cString: executable)
        return DiskBlocker(pid: pid, startedAt: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)",
                           name: URL(fileURLWithPath: path).lastPathComponent, executable: path, paths: paths)
    }

    private static func scan(_ disk: Disk) -> BlockerReport {
        let layout = DiskInspection.read(disk)
        guard layout.present else { return BlockerReport(blockers: []) }
        var holders: [Int32: Set<String>] = [:]
        var limitations: Set<String> = []
        let paths = layout.volumes.map { ($0.path, true) } + layout.devicePaths.map { ($0, false) }
        for (path, volume) in paths {
            let flags = UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY | (volume ? PROC_LISTPIDSPATH_PATH_IS_VOLUME : 0))
            let required = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, flags, nil, 0)
            guard required > 0 else {
                if required < 0 { limitations.insert("Process inspection denied or unavailable for \(path) (\(errno))") }
                continue
            }
            var pids = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.stride + 256)
            let size = Int32(pids.count * MemoryLayout<Int32>.stride)
            let used = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, flags, &pids, size)
            guard used >= 0 else { limitations.insert("Process inspection failed for \(path) (\(errno))"); continue }
            if used >= size { limitations.insert("Process list changed during inspection; results may be incomplete") }
            for pid in pids.prefix(Int(used) / MemoryLayout<Int32>.stride) where pid > 0 {
                holders[pid, default: []].insert(path)
            }
        }
        var blockers: [DiskBlocker] = []
        for (pid, paths) in holders.sorted(by: { $0.key < $1.key }) {
            let detail = references(pid: pid, roots: layout.volumes.map(\.path), devicePaths: layout.devicePaths)
            if let process = identity(pid, paths: detail.isEmpty ? paths.sorted() : detail) { blockers.append(process) }
            else { limitations.insert("Holder PID \(pid) exited or its identity is not accessible") }
        }
        if blockers.isEmpty {
            limitations.insert("No inspectable user-process reference found. A kernel, driver, permission, or hidden process can still prevent ejection.")
        }
        return BlockerReport(blockers: blockers, limitations: limitations.sorted())
    }

    private static func references(pid: Int32, roots: [String], devicePaths: [String]) -> [String] {
        func matches(_ path: String) -> Bool {
            devicePaths.contains(path) || roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var paths: Set<String> = []
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if required > 0, required < 16_000_000 {
            var fds: [proc_fdinfo] = .init(repeating: .init(), count: Int(required) / MemoryLayout<proc_fdinfo>.stride + 32)
            let size = Int32(fds.count * MemoryLayout<proc_fdinfo>.stride)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            if used > 0 {
                for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    var file = vnode_fdinfowithpath()
                    let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                    if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &file, size) == size,
                       file.pfi.fi_openflags & UInt32(O_EVTONLY) == 0 {
                        let path = withUnsafeBytes(of: &file.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                        if matches(path) { paths.insert(path) }
                    }
                }
            }
        }
        var directories = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &directories, size) == size {
            let path = withUnsafeBytes(of: &directories.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if matches(path) { paths.insert("Working directory: " + path) }
        }
        return paths.sorted()
    }
}

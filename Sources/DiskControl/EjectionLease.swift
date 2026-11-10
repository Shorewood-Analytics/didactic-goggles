import Foundation
import Darwin

/// Serializes GUI, Shortcuts, and CLI requests across processes for this user.
final class EjectionLease {
    private var descriptor: Int32 = -1
    func acquire() -> Bool {
        guard descriptor == -1 else { return false }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DiskWatch", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        let fd = open(folder.appendingPathComponent("ejection.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }
    func release() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

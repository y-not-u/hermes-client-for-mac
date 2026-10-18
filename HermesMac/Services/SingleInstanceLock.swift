import Foundation
import Darwin

/// A per-user, per-bundle lock held until process exit, including forced exits.
final class SingleInstanceLock {
    private let descriptor: Int32

    init(identifier: String, directory: URL = FileManager.default.temporaryDirectory) throws {
        let url = directory.appendingPathComponent("\(identifier).instance.lock")
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func acquire() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    // Never unlink the file: a competing process may already have it open.
    deinit { close(descriptor) }
}

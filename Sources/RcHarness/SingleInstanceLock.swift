import Darwin
import Foundation

final class SingleInstanceLock {
    enum Failure: Error { case alreadyRunning }
    private let fileDescriptor: Int32

    init(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        fileDescriptor = descriptor
        let processID = "\(getpid())\n"
        ftruncate(descriptor, 0)
        _ = processID.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

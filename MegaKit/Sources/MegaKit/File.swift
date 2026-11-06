import Darwin
import Foundation

/// An open file descriptor that child tasks can share. Whoever opens it closes it.
struct File: Sendable {
    let descriptor: Int32

    init(_ url: URL, flags: Int32) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, flags, 0o644) } ?? -1
        }
        guard descriptor >= 0 else { throw flags & O_ACCMODE == O_RDONLY ? MegaError.diskReadFailed : .diskWriteFailed }
        self.descriptor = descriptor
    }

    func close() { Darwin.close(descriptor) }

    var length: Int { Int(lseek(descriptor, 0, SEEK_END)) }

    func truncate(to size: Int) throws {
        guard ftruncate(descriptor, off_t(size)) == 0 else { throw MegaError.diskWriteFailed }
    }

    func write(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws {
        var done = 0
        while done < buffer.count {
            let result = pwrite(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            guard result > 0 else { throw MegaError.diskWriteFailed }
            done += result
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws {
        var done = 0
        while done < buffer.count {
            let result = pread(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            guard result > 0 else { throw MegaError.diskReadFailed }
            done += result
        }
    }
}

import Foundation
import Darwin

enum BoundedFileReadError: Error, Equatable { case missing, unreadable, tooLarge }

/// Reads one source file whole. The size limit is checked on the opened file itself (after any
/// symlink is followed), before a byte is read, and the read stops one byte past the limit, so a
/// file that grows after the check is refused too. The worst single allocation is `maxBytes + 1`.
func readBoundedFile(_ url: URL, maxBytes: Int) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw errno == ENOENT ? BoundedFileReadError.missing : .unreadable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw BoundedFileReadError.unreadable }
    guard info.st_size >= 0, info.st_size <= maxBytes else { throw BoundedFileReadError.tooLarge }
    let data: Data
    do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { throw BoundedFileReadError.unreadable }
    guard data.count <= maxBytes else { throw BoundedFileReadError.tooLarge }
    return data
}

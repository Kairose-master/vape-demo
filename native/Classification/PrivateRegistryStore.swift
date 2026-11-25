import Foundation
import Darwin

// One process owns this dedicated directory for the store's lifetime. Never place source files here.
final class PrivateRegistryStore: ClassificationStorage {
    private let directory: URL
    private let lockFD: Int32
    private let maximumBytes = 16 * 1024 * 1024
    init(directory: URL) throws {
        let url = directory.standardizedFileURL
        guard url.isFileURL, url.path == url.resolvingSymlinksInPath().path else { throw RegistryError.unsafeFile }
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw RegistryError.unavailable }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw RegistryError.unsafeFile }
        let fd = Darwin.open(url.appendingPathComponent("registry.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RegistryError.unavailable }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw RegistryError.unavailable
        }
        self.directory = url; self.lockFD = fd
    }
    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
    func load() throws -> Data? {
        let path = directory.appendingPathComponent("registry.json").path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw RegistryError.corruptStore }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw RegistryError.corruptStore }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw RegistryError.corruptStore }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= maximumBytes else { throw RegistryError.corruptStore }
        }
        guard data.count == info.st_size else { throw RegistryError.corruptStore }
        return data
    }
    func save(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw RegistryError.persistenceFailed }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp").path
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RegistryError.persistenceFailed }
        defer { Darwin.close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RegistryError.persistenceFailed }
                offset += n
            }
        }
        guard fsync(fd) == 0, rename(temporary, directory.appendingPathComponent("registry.json").path) == 0 else { throw RegistryError.persistenceFailed }
        let parentFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw RegistryError.persistenceFailed }
        defer { Darwin.close(parentFD) }
        guard fsync(parentFD) == 0 else { throw RegistryError.persistenceFailed }
    }
}

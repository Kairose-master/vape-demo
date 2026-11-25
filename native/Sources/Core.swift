import Foundation
import CryptoKit
import Darwin

struct Rule: Codable {
    let level, role, workflow, operation, destination, effect: String
}
struct Policy: Codable {
    let version: Int
    let organization: String
    let levels: [String]
    let defaultEffect: String
    let rules: [Rule]
    func validate() throws {
        guard version > 0, defaultEffect == "deny", !levels.isEmpty,
              Set(levels).count == levels.count, !organization.isEmpty,
              rules.allSatisfy({ levels.contains($0.level) && ["allow", "deny"].contains($0.effect)
                  && ["read","write","model_send","tool_send"].contains($0.operation)
                  && !$0.role.isEmpty && !$0.workflow.isEmpty && !$0.destination.isEmpty }) else {
            throw GateError.invalidPolicy
        }
    }
    func allows(level: String, role: String, workflow: String, operation: String, destination: String) -> Bool {
        guard (try? validate()) != nil else { return false }
        let matched = rules.filter { $0.level == level && $0.role == role && $0.workflow == workflow
            && $0.operation == operation && $0.destination == destination }
        return !matched.contains { $0.effect == "deny" } && matched.contains { $0.effect == "allow" }
    }
}
struct Resource: Codable {
    let id, level, fileName, initialSHA256: String
}
struct Fixture: Codable {
    let folder: String
    let resources: [Resource]
}
struct BrokerContext {
    // Set by trusted native controller, never accepted from the worker or a web request.
    let role: String
    let workflow: String
}
enum GateError: Error, CustomStringConvertible {
    case denied, wrongFolder, unknownResource, unsafeFile, invalidPolicy, posix(Int32)
    var description: String {
        switch self {
        case .denied: return "APP_POLICY_DENY (OS file operation not attempted)"
        case .wrongFolder: return "Only the prepared synthetic test folder is accepted"
        case .unknownResource: return "Unknown resource"
        case .unsafeFile: return "Not a regular single-link synthetic resource"
        case .invalidPolicy: return "Invalid organization policy"
        case .posix(let code): return "OS_ERROR errno=\(code)"
        }
    }
}
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 { if errno == EINTR { continue }; throw GateError.posix(errno) }
            if count == 0 { throw GateError.posix(EIO) }
            offset += count
        }
    }
}
final class FileGate {
    private let rootFD: Int32
    private let fixture: Fixture
    let policy: Policy
    private(set) var writeAttempts = 0
    init(folder: URL, fixture: Fixture, policy: Policy) throws {
        try policy.validate()
        guard folder.standardizedFileURL.path == fixture.folder,
              folder.resolvingSymlinksInPath().path == fixture.folder else { throw GateError.wrongFolder }
        self.fixture = fixture; self.policy = policy
        rootFD = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if rootFD < 0 { throw GateError.posix(errno) }
    }
    deinit { Darwin.close(rootFD) }
    func resource(_ id: String) throws -> Resource {
        guard let resource = fixture.resources.first(where: {$0.id == id}),
              resource.fileName == URL(fileURLWithPath: resource.fileName).lastPathComponent,
              !resource.fileName.contains("/"), resource.fileName.hasSuffix(".txt") else { throw GateError.unknownResource }
        return resource
    }
    private func descriptor(_ resource: Resource, write: Bool) throws -> Int32 {
        if write { writeAttempts += 1 }
        let flags = (write ? O_WRONLY | O_APPEND : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let fd = openat(rootFD, resource.fileName, flags)
        if fd < 0 { throw GateError.posix(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size <= 16384 else {
            Darwin.close(fd); throw GateError.unsafeFile
        }
        return fd
    }
    func read(id: String, context: BrokerContext) throws -> Data {
        let resource = try self.resource(id)
        guard policy.allows(level: resource.level, role: context.role, workflow: context.workflow,
                            operation: "read", destination: "file") else { throw GateError.denied }
        let fd = try descriptor(resource, write: false); defer { Darwin.close(fd) }
        var buffer = [UInt8](repeating: 0, count: 16385)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 { throw GateError.posix(errno) }
        guard count <= 16384 else { throw GateError.unsafeFile }
        return Data(buffer.prefix(count))
    }
    func appendSynthetic(id: String, context: BrokerContext, intent: () throws -> Void) throws {
        let resource = try self.resource(id)
        guard policy.allows(level: resource.level, role: context.role, workflow: context.workflow,
                            operation: "write", destination: "file") else { throw GateError.denied }
        // Durable intent must succeed before opening the resource for writing.
        try intent()
        let fd = try descriptor(resource, write: true); defer { Darwin.close(fd) }
        try writeAll(fd, Data("\n[SYNTHETIC VAPE L3 WRITE — NO REAL DATA]\n".utf8))
        if fsync(fd) != 0 { throw GateError.posix(errno) }
    }
}

final class NativeEvidence {
    private let fd: Int32
    let url: URL
    init(folder: URL) throws {
        url = folder.appendingPathComponent("evidence-\(UUID().uuidString).jsonl")
        fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 { throw GateError.posix(errno) }
    }
    deinit { Darwin.close(fd) }
    func append(_ facts: [String: Any]) throws {
        var record = facts
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())
        record["evidenceKind"] = "native-local-observation-not-chain-commit"
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
        try writeAll(fd, data)
        if fsync(fd) != 0 { throw GateError.posix(errno) }
    }
}

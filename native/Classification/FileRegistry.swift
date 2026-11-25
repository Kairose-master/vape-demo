import Foundation
import CryptoKit
import Darwin

// This module has no network client, model client, ledger client, or application entry point.
enum RegisteredLevel: Int, Codable { case one = 1, two = 2, three = 3 }
struct RegistryPrincipal { let id: String } // Must come from the trusted native/auth controller, never request JSON.
struct RegisteredFile: Codable, Equatable {
    let resource_id: UUID
    let level: RegisteredLevel
    let classification_revision: Int
    let policy_version: Int
}
struct ClassificationEvent: Codable, Equatable {
    let event_id: UUID
    let resource_id: UUID?
    let kind: String
    let level: RegisteredLevel?
    let previous_level: RegisteredLevel?
    let classification_revision: Int?
    let policy_version: Int
    let reason: String?
}
struct TextPreparationDecision: Codable, Equatable {
    let decision_id: UUID
    let resource_id: UUID
    let level: RegisteredLevel?
    let classification_revision: Int?
    let policy_version: Int
    let action: String
    let model_alias: String
    let allowed: Bool
    let reason: String
}
// Intentionally not Codable: plaintext can only be handed to a trusted local caller after authorization.
struct PreparedModelText {
    let text: String
    let evidence: TextPreparationDecision
}
struct ModelTextRequest: Decodable {
    let resource_id: UUID
    let policy_version: Int
    let action: String
    let model_alias: String
    init(resourceID: UUID, policyVersion: Int, action: String = "model_send", modelAlias: String) {
        resource_id = resourceID; policy_version = policyVersion; self.action = action; model_alias = modelAlias
    }
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard Set(c.allKeys.map(\.stringValue)) == Set(["resource_id","policy_version","action","model_alias"]) else { throw RegistryError.invalidRequest }
        resource_id = try c.decode(UUID.self, forKey: Key(stringValue:"resource_id")!)
        policy_version = try c.decode(Int.self, forKey: Key(stringValue:"policy_version")!)
        action = try c.decode(String.self, forKey: Key(stringValue:"action")!)
        model_alias = try c.decode(String.self, forKey: Key(stringValue:"model_alias")!)
    }
}
struct ClassificationPolicyInput {
    let principal: RegistryPrincipal
    let resource: RegisteredFile
    let action: String
    let modelAlias: String
}
struct ClassificationPolicySnapshot {
    let version: Int
    // Capture an immutable policy in this closure. Unknown action/alias/level must return false.
    let permits: (ClassificationPolicyInput) -> Bool
}
protocol UserFileSelection { func chooseFile() throws -> URL? }
protocol SelectedFileAccess {
    func begin(_ url: URL) -> Bool
    func end(_ url: URL)
    func makeBookmark(_ url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool)
}
protocol ClassificationStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
}
enum RegistryError: String, Error {
    case invalidRequest, notOwner, unregistered, needsRegistration, changedFile, staleBookmark
    case scopeDenied, unsafeFile, staleRevision, stalePolicy, denied, unsupportedFormat, tooLarge
    case unavailable, corruptStore, persistenceFailed, invalidPrincipal
}
private struct FileFingerprint: Codable, Equatable {
    let device: Int64, inode: UInt64, size: Int64
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    let digest: String
}
private struct PrivateRegistration: Codable {
    let id: UUID, owner: String, bookmark: Data, fingerprint: FileFingerprint
    var level: RegisteredLevel, revision: Int, active: Bool
    let isTextExtension: Bool
    let locationDigest: String
}
private struct RegistryState: Codable {
    var schema = 1
    var observedPolicyVersion = 0
    var registrations = [PrivateRegistration]()
    var events = [ClassificationEvent]()
    var decisions = [TextPreparationDecision]()
}

final class FileClassificationRegistry {
    static let maximumTextBytes = 64 * 1024
    private let storage: ClassificationStorage
    private let access: SelectedFileAccess
    private let policy: () throws -> ClassificationPolicySnapshot
    private let lock = NSRecursiveLock()
    private var state: RegistryState
    private var poisoned = false

    init(storage: ClassificationStorage, access: SelectedFileAccess,
         policy: @escaping () throws -> ClassificationPolicySnapshot) throws {
        self.storage = storage; self.access = access; self.policy = policy
        if let data = try storage.load() {
            do { state = try JSONDecoder().decode(RegistryState.self, from: data) }
            catch { throw RegistryError.corruptStore }
            guard state.schema == 1, state.observedPolicyVersion >= 0,
                  Set(state.registrations.map(\.id)).count == state.registrations.count,
                  state.registrations.allSatisfy({ !$0.owner.isEmpty && $0.revision > 0 && !$0.bookmark.isEmpty }),
                  state.events.allSatisfy({$0.policy_version > 0}),
                  state.decisions.allSatisfy({$0.policy_version > 0}) else { throw RegistryError.corruptStore }
        } else { state = RegistryState() }
    }
    private func commit(_ next: RegistryState) throws {
        guard !poisoned else { throw RegistryError.persistenceFailed }
        do { try storage.save(JSONEncoder().encode(next)); state = next }
        catch { poisoned = true; throw RegistryError.persistenceFailed }
    }
    private func capturePolicy() throws -> ClassificationPolicySnapshot {
        guard !poisoned else { throw RegistryError.persistenceFailed }
        let snapshot = try policy()
        guard snapshot.version > 0, snapshot.version >= state.observedPolicyVersion else { throw RegistryError.stalePolicy }
        if snapshot.version > state.observedPolicyVersion {
            var next = state; next.observedPolicyVersion = snapshot.version
            next.events.append(ClassificationEvent(event_id: UUID(), resource_id: nil, kind: "policy_version_observed", level: nil, previous_level: nil, classification_revision: nil, policy_version: snapshot.version, reason: nil))
            try commit(next)
        }
        return snapshot
    }
    private func index(_ id: UUID, _ principal: RegistryPrincipal) throws -> Int {
        guard !principal.id.isEmpty else { throw RegistryError.invalidPrincipal }
        guard let i = state.registrations.firstIndex(where: {$0.id == id}) else { throw RegistryError.unregistered }
        guard state.registrations[i].owner == principal.id else { throw RegistryError.notOwner }
        return i
    }
    private func descriptor(_ record: PrivateRegistration, version: Int) -> RegisteredFile {
        RegisteredFile(resource_id: record.id, level: record.level, classification_revision: record.revision, policy_version: version)
    }
    private func scoped<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        guard access.begin(url) else { throw RegistryError.scopeDenied }
        defer { access.end(url) }
        return try body()
    }
    private func metadata(_ info: stat, digest: String) -> FileFingerprint {
        FileFingerprint(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                        modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                        changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec), digest: digest)
    }
    // Read-only descriptor, no symlink traversal, bounded allocations; registration hashes in chunks.
    private func inspect(_ url: URL, collectText: Bool) throws -> (FileFingerprint, Data?) {
        guard url.isFileURL else { throw RegistryError.unsafeFile }
        let normal = url.standardizedFileURL
        guard normal.path == normal.resolvingSymlinksInPath().path else { throw RegistryError.unsafeFile }
        let fd = Darwin.open(normal.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RegistryError.unavailable }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0 else { throw RegistryError.unsafeFile }
        if collectText && before.st_size > Self.maximumTextBytes { throw RegistryError.tooLarge }
        var hasher = SHA256(), bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        var count: Int64 = 0
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw RegistryError.unavailable }
            if n == 0 { break }
            count += Int64(n)
            guard count <= before.st_size else { throw RegistryError.changedFile }
            let chunk = Data(buffer[0..<n]); hasher.update(data: chunk)
            if collectText { bytes.append(chunk) }
        }
        guard fstat(fd, &after) == 0, metadata(before, digest: "") == metadata(after, digest: ""), count == before.st_size else { throw RegistryError.changedFile }
        // Detect replacing the selected path while its old inode was being read.
        var current = stat()
        guard lstat(normal.path, &current) == 0, metadata(current, digest: "") == metadata(after, digest: "") else { throw RegistryError.changedFile }
        let digest = hasher.finalize().map {String(format: "%02x", $0)}.joined()
        return (metadata(after, digest: digest), collectText ? bytes : nil)
    }
    private func invalidate(_ i: Int, version: Int, reason: RegistryError) throws {
        guard state.registrations[i].active else { return }
        var next = state; next.registrations[i].active = false
        let record = next.registrations[i]
        next.events.append(ClassificationEvent(event_id: UUID(), resource_id: record.id, kind: "registration_invalidated", level: record.level, previous_level: nil, classification_revision: record.revision, policy_version: version, reason: reason.rawValue))
        try commit(next)
    }
    private func locationDigest(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map {String(format: "%02x", $0)}.joined()
    }
    private func inspectRegistered(_ i: Int, version: Int, collectText: Bool) throws -> Data? {
        let record = state.registrations[i]
        guard record.active else { throw RegistryError.needsRegistration }
        do {
            let resolved = try access.resolve(record.bookmark)
            guard !resolved.stale else { throw RegistryError.staleBookmark }
            guard locationDigest(resolved.url) == record.locationDigest else { throw RegistryError.changedFile }
            return try scoped(resolved.url) {
                let (fingerprint, bytes) = try inspect(resolved.url, collectText: collectText)
                guard fingerprint == record.fingerprint else { throw RegistryError.changedFile }
                return bytes
            }
        } catch {
            let reason = error as? RegistryError ?? .unavailable
            // A format/size restriction is not a change to registration. All access/identity failures stick.
            if reason != .tooLarge && reason != .unsupportedFormat { try invalidate(i, version: version, reason: reason) }
            throw reason
        }
    }

    // Only the trusted native controller supplies the selector, principal and intended grade.
    // Cancellation is not registration, and never touches the original file.
    func register(using selector: UserFileSelection, level: RegisteredLevel, principal: RegistryPrincipal) throws -> RegisteredFile? {
        guard !principal.id.isEmpty else { throw RegistryError.invalidPrincipal }
        guard let url = try selector.chooseFile() else { return nil }
        lock.lock(); defer {lock.unlock()}
        let snapshot = try capturePolicy()
        return try scoped(url) {
            let (fingerprint, _) = try inspect(url, collectText: false)
            let bookmark = try access.makeBookmark(url)
            guard !bookmark.isEmpty else { throw RegistryError.unavailable }
            let record = PrivateRegistration(id: UUID(), owner: principal.id, bookmark: bookmark,
                                             fingerprint: fingerprint, level: level, revision: 1, active: true,
                                             isTextExtension: url.pathExtension.lowercased() == "txt", locationDigest: locationDigest(url))
            var next = state; next.registrations.append(record)
            next.events.append(ClassificationEvent(event_id: UUID(), resource_id: record.id, kind: "registered", level: level, previous_level: nil, classification_revision: 1, policy_version: snapshot.version, reason: nil))
            try commit(next)
            return descriptor(record, version: snapshot.version)
        }
    }
    func changeLevel(resourceID: UUID, to level: RegisteredLevel, expectedRevision: Int, principal: RegistryPrincipal) throws -> RegisteredFile {
        lock.lock(); defer {lock.unlock()}
        let snapshot = try capturePolicy(), i = try index(resourceID, principal)
        guard state.registrations[i].revision == expectedRevision else { throw RegistryError.staleRevision }
        _ = try inspectRegistered(i, version: snapshot.version, collectText: false)
        if state.registrations[i].level == level { return descriptor(state.registrations[i], version: snapshot.version) }
        var next = state; let old = next.registrations[i].level
        next.registrations[i].level = level; next.registrations[i].revision += 1
        let record = next.registrations[i]
        next.events.append(ClassificationEvent(event_id: UUID(), resource_id: record.id, kind: "level_changed", level: level, previous_level: old, classification_revision: record.revision, policy_version: snapshot.version, reason: nil))
        try commit(next)
        return descriptor(record, version: snapshot.version)
    }
    // Private in-process transaction. The app owns all closures; no HTTP can supply them.
    // Authorization is checked before resolving any bookmark, then again at dispatch.
    func consumePreparedText(_ request: ModelTextRequest, expectedRevision: Int, principal: RegistryPrincipal,
                             authorize: (RegisteredFile, String?) throws -> Void,
                             consume: (String, RegisteredFile, () throws -> RegisteredFile) throws -> Void) throws {
        lock.lock(); defer {lock.unlock()}
        let i = try index(request.resource_id, principal)
        func current() throws -> RegisteredFile {
            let snapshot = try capturePolicy(), record = state.registrations[i]
            guard record.active else {throw RegistryError.needsRegistration}
            guard record.revision == expectedRevision else {throw RegistryError.staleRevision}
            guard snapshot.version == request.policy_version else {throw RegistryError.stalePolicy}
            let resource = descriptor(record, version:snapshot.version)
            guard snapshot.permits(ClassificationPolicyInput(principal:principal,resource:resource,action:request.action,modelAlias:request.model_alias)) else {throw RegistryError.denied}
            return resource
        }
        try authorize(current(), nil) // Configuration and route gates precede body access.
        _ = try current() // An authorization callback may revoke or reclassify the resource.
        let prepared = try prepareTextRevisionBound(request,expectedRevision:expectedRevision,principal:principal)
        let digest = SHA256.hash(data:Data(prepared.text.utf8)).map {String(format:"%02x",$0)}.joined()
        try authorize(current(), digest)
        let resource = try current()
        // Recheck selected file identity/fingerprint after the final approval callback.
        _ = try inspectRegistered(i,version:resource.policy_version,collectText:false)
        _ = try current()
        try consume(prepared.text,resource,{
            let latest = try current()
            _ = try self.inspectRegistered(i,version:latest.policy_version,collectText:false)
            return try current()
        }) // Exactly one synchronous handoff under the registry lock.
    }

    // Integration entrypoint: stale classification is rejected before resolving a bookmark or reading bytes.
    func prepareTextRevisionBound(_ request: ModelTextRequest, expectedRevision: Int, principal: RegistryPrincipal) throws -> PreparedModelText {
        lock.lock(); defer {lock.unlock()}
        let i = try index(request.resource_id, principal)
        guard state.registrations[i].revision == expectedRevision else { throw RegistryError.staleRevision }
        return try prepareText(request, principal: principal)
    }
    func prepareText(_ request: ModelTextRequest, principal: RegistryPrincipal) throws -> PreparedModelText {
        lock.lock(); defer {lock.unlock()}
        let snapshot = try capturePolicy()
        // Invalid strings never enter history, so aliases/actions cannot smuggle arbitrary paths/text.
        guard request.action == "model_send", request.model_alias.range(of: "^[a-z][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else { throw RegistryError.invalidRequest }
        let i = try index(request.resource_id, principal)
        let record = state.registrations[i]
        var decisionReason: RegistryError?
        var text: String?
        do {
            guard record.active else { throw RegistryError.needsRegistration }
            guard request.policy_version == snapshot.version else { throw RegistryError.stalePolicy }
            let resource = descriptor(record, version: snapshot.version)
            guard snapshot.permits(ClassificationPolicyInput(principal: principal, resource: resource, action: request.action, modelAlias: request.model_alias)) else { throw RegistryError.denied }
            // Detect changes even for unsupported file formats, before reporting format restrictions.
            _ = try inspectRegistered(i, version: snapshot.version, collectText: false)
            guard record.isTextExtension else { throw RegistryError.unsupportedFormat }
            guard let bytes = try inspectRegistered(i, version: snapshot.version, collectText: true),
                  let value = String(data: bytes, encoding: .utf8),
                  value.unicodeScalars.allSatisfy({$0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 127)}) else { throw RegistryError.unsupportedFormat }
            // Do not release plaintext if authorization version changed during the read.
            guard try policy().version == snapshot.version else { throw RegistryError.stalePolicy }
            text = value
        } catch { decisionReason = error as? RegistryError ?? .unavailable }
        let decision = TextPreparationDecision(decision_id: UUID(), resource_id: record.id, level: record.level,
            classification_revision: record.revision, policy_version: snapshot.version, action: request.action,
            model_alias: request.model_alias, allowed: decisionReason == nil, reason: decisionReason?.rawValue ?? "authorized_text_snapshot")
        var next = state; next.decisions.append(decision); try commit(next)
        if let reason = decisionReason { throw reason }
        return PreparedModelText(text: text!, evidence: decision)
    }
    func history(principal: RegistryPrincipal) -> [ClassificationEvent] {
        lock.lock(); defer {lock.unlock()}
        let ids = Set(state.registrations.filter {$0.owner == principal.id}.map(\.id))
        return state.events.filter {$0.resource_id == nil || ids.contains($0.resource_id!)}
    }
    func decisions(principal: RegistryPrincipal) -> [TextPreparationDecision] {
        lock.lock(); defer {lock.unlock()}
        let ids = Set(state.registrations.filter {$0.owner == principal.id}.map(\.id))
        return state.decisions.filter {ids.contains($0.resource_id)}
    }
}

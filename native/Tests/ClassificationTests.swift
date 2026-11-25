import Foundation
import Darwin

final class MemoryStore: ClassificationStorage {
    var data: Data?; var fail = false
    func load() throws -> Data? { data }
    func save(_ value: Data) throws { if fail { throw RegistryError.persistenceFailed }; data = value }
}
struct Picker: UserFileSelection { let url: URL?; func chooseFile() throws -> URL? { url } }
final class Scope: SelectedFileAccess {
    var redirected: URL?; var onBegin: (() -> Void)?
    var allowed = true, stale = false; var starts = 0, stops = 0
    func begin(_ url: URL) -> Bool { starts += 1; onBegin?(); return allowed }
    func end(_ url: URL) { stops += 1 }
    func makeBookmark(_ url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) { (redirected ?? URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self)), stale) }
}
@main struct ClassificationTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    static func reject(_ expected: RegistryError, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected \(expected)") } catch { check(error as? RegistryError == expected, "Unexpected \(error), expected \(expected)") }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let owner = RegistryPrincipal(id: "local-owner"), other = RegistryPrincipal(id: "other")
        let scope = Scope(), store = MemoryStore(); var version = 1
        let policy: () -> ClassificationPolicySnapshot = { ClassificationPolicySnapshot(version: version, permits: {$0.resource.level == .one && $0.modelAlias == "local-test"}) }
        let registry = try FileClassificationRegistry(storage: store, access: scope, policy: policy)
        func file(_ name: String, _ data: Data) throws -> URL { let u = root.appendingPathComponent(name); try data.write(to: u); return u }
        func register(_ u: URL, _ level: RegisteredLevel = .one) throws -> RegisteredFile { try registry.register(using: Picker(url:u), level:level, principal:owner)! }
        func request(_ r: RegisteredFile) -> ModelTextRequest { ModelTextRequest(resourceID:r.resource_id, policyVersion:version, modelAlias:"local-test") }
        check(try registry.register(using: Picker(url:nil), level:.one, principal:owner) == nil, "cancel")
        check(scope.starts == 0, "cancel scope")
        let original = Data("SYNTHETIC_SECRET hello\n".utf8), url = try file("private sentinel space.txt", original)
        let r = try register(url)
        let prepared = try registry.prepareText(request(r), principal:owner)
        check(prepared.text == String(decoding:original,as:UTF8.self), "text")
        reject(.notOwner) { _ = try registry.prepareText(request(r), principal:other) }
        reject(.unregistered) { _ = try registry.prepareText(ModelTextRequest(resourceID:UUID(),policyVersion:1,modelAlias:"local-test"),principal:owner) }
        let changed = try registry.changeLevel(resourceID:r.resource_id,to:.three,expectedRevision:1,principal:owner)
        check(changed.classification_revision == 2, "revision")
        let beforeStaleRead = scope.starts
        reject(.staleRevision) { _ = try registry.prepareTextRevisionBound(request(r),expectedRevision:1,principal:owner) }
        check(scope.starts == beforeStaleRead, "stale revision denied before body/scope")

        reject(.denied) { _ = try registry.prepareText(request(r),principal:owner) }
        check(registry.decisions(principal:owner).first == prepared.evidence, "old decision unchanged")
        reject(.staleRevision) { _ = try registry.changeLevel(resourceID:r.resource_id,to:.one,expectedRevision:1,principal:owner) }
        _ = try registry.changeLevel(resourceID:r.resource_id,to:.one,expectedRevision:2,principal:owner)
        version = 2
        reject(.stalePolicy) { _ = try registry.prepareText(ModelTextRequest(resourceID:r.resource_id,policyVersion:1,modelAlias:"local-test"),principal:owner) }
        _ = try registry.prepareText(request(r),principal:owner)
        version = 1
        reject(.stalePolicy) { _ = try registry.prepareText(request(r),principal:owner) }; version = 2
        check(try Data(contentsOf:url) == original, "source untouched")
        let publicData = try JSONEncoder().encode(registry.history(principal:owner)) + JSONEncoder().encode(registry.decisions(principal:owner))
        let publicText = String(decoding:publicData,as:UTF8.self)
        for forbidden in ["SYNTHETIC_SECRET", "sentinel", root.path, "bookmark", "digest", "local-owner"] { check(!publicText.contains(forbidden), "public leakage") }
        let forged = "{\"resource_id\":\"\(r.resource_id)\",\"policy_version\":2,\"action\":\"model_send\",\"model_alias\":\"local-test\",\"level\":1}"
        reject(.invalidRequest) { _ = try JSONDecoder().decode(ModelTextRequest.self,from:Data(forged.utf8)) }
        reject(.invalidRequest) { _ = try registry.prepareText(ModelTextRequest(resourceID:r.resource_id,policyVersion:2,modelAlias:"/private/path"),principal:owner) }
        try Data("changed".utf8).write(to:url)
        reject(.changedFile) { _ = try registry.prepareText(request(r),principal:owner) }
        try original.write(to:url)
        reject(.needsRegistration) { _ = try registry.prepareText(request(r),principal:owner) }
        let again = try register(url); check(again.resource_id != r.resource_id, "fresh id")
        let binary = try register(file("binary.pdf",Data([0,1,2])))
        reject(.unsupportedFormat) { _ = try registry.prepareText(request(binary),principal:owner) }
        let big = try register(file("big.txt",Data(repeating:65,count:65537)))
        reject(.tooLarge) { _ = try registry.prepareText(request(big),principal:owner) }
        for (name,data) in [("nul.txt",Data([65,0])),("invalid.txt",Data([255]))] {
            let invalid = try register(file(name,data)); reject(.unsupportedFormat) { _ = try registry.prepareText(request(invalid),principal:owner) }
        }
        scope.stale = true
        reject(.staleBookmark) { _ = try registry.prepareText(request(again),principal:owner) }; scope.stale = false
        reject(.needsRegistration) { _ = try registry.prepareText(request(again),principal:owner) }
        check(scope.starts == scope.stops, "scope balanced")
        scope.allowed = false
        reject(.scopeDenied) { _ = try register(url) }; scope.allowed = true
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:url)
        reject(.unsafeFile) { _ = try register(link) }
        reject(.unsafeFile) { _ = try register(root) }
        let hard = root.appendingPathComponent("hard.txt")
        try FileManager.default.linkItem(at:url,to:hard)
        reject(.unsafeFile) { _ = try register(hard) }
        let diskURL = root.appendingPathComponent("private registry")
        do {
            let disk = try PrivateRegistryStore(directory:diskURL)
            try disk.save(store.data!)
            let restored = try FileClassificationRegistry(storage:disk,access:scope,policy:policy)
            check(restored.decisions(principal:owner) == registry.decisions(principal:owner), "persistent history")
            reject(.unavailable) { _ = try PrivateRegistryStore(directory:diskURL) }
        }
        do { let disk = try PrivateRegistryStore(directory:diskURL); check(try disk.load() == store.data, "reopen") }
        let corrupt = MemoryStore(); corrupt.data = Data("invalid".utf8)
        reject(.corruptStore) { _ = try FileClassificationRegistry(storage:corrupt,access:scope,policy:policy) }
        let scopeFile = try register(file("scope.txt",Data("synthetic".utf8)))
        scope.allowed = false
        reject(.scopeDenied) { _ = try registry.prepareText(request(scopeFile),principal:owner) }
        scope.allowed = true
        reject(.needsRegistration) { _ = try registry.prepareText(request(scopeFile),principal:owner) }
        let movingURL = try file("moving.txt",Data("synthetic".utf8))
        let moving = try register(movingURL)
        let movedURL = root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at:movingURL,to:movedURL); scope.redirected = movedURL
        reject(.changedFile) { _ = try registry.prepareText(request(moving),principal:owner) }; scope.redirected = nil
        let race = try register(file("policy-race.txt",Data("synthetic".utf8)))
        scope.onBegin = { version = 3 }
        reject(.stalePolicy) { _ = try registry.prepareText(ModelTextRequest(resourceID:race.resource_id,policyVersion:2,modelAlias:"local-test"),principal:owner) }
        scope.onBegin = nil
        let final = try register(file("final.txt",Data("synthetic".utf8)))
        store.fail = true
        reject(.persistenceFailed) { _ = try registry.prepareText(request(final),principal:owner) }
        reject(.persistenceFailed) { _ = try registry.prepareText(request(final),principal:owner) }
        print("PASS classification: \(count) assertions; synthetic files only; picker/scopes injected")
    }
}

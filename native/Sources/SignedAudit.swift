import Foundation
import CryptoKit
import Darwin

let nativeEvidenceSchema = "vape-native-ed25519-merkle-v1"
func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func exclusiveDurableWrite(_ data: Data, to url: URL) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if fd < 0 { throw GateError.posix(errno) }
    defer { Darwin.close(fd) }
    try writeAll(fd, data)
    if fsync(fd) != 0 { throw GateError.posix(errno) }
    let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if directory < 0 { throw GateError.posix(errno) }
    defer { Darwin.close(directory) }
    if fsync(directory) != 0 { throw GateError.posix(errno) }
}
struct SignedLeaf: Codable {
    let event: [String: String]
    let signature: String
}
struct Sibling: Codable { let side: String; let hash: String }
struct InclusionProof: Codable { let leafIndex: Int; let treeSize: Int; let siblings: [Sibling] }
struct NativeCheckpoint: Codable {
    let schema, kind, id, runID, keyID, tipEventID, root: String
    let treeSize: Int
}
struct SignedCheckpoint: Codable { let checkpoint: NativeCheckpoint; let signature: String }
struct NativeBundle: Codable {
    let schema: String
    let leaf: SignedLeaf
    let policy: Policy
    let proof: InclusionProof
    let checkpoint: SignedCheckpoint
}
struct NativePackage: Codable { let schema: String; let runID: String; let bundles: [NativeBundle] }
struct NativeTrustSet: Codable { let schema: String; let runID: String; let checkpoints: [SignedCheckpoint] }
struct VerificationRow: Codable {
    let eventID, requestID, phase, enforcement, resourceID, decision: String
}
struct NativeVerification: Codable {
    let verdict: String
    let valid: Bool
    let complete: Bool
    let reason: String
    let events: [VerificationRow]
}
func eventMessage(_ event: [String: String]) throws -> Data { try Data("VAPE-NATIVE-EVENT-v1\0".utf8) + canonical(event) }
func checkpointMessage(_ cp: NativeCheckpoint) throws -> Data { try Data("VAPE-NATIVE-CHECKPOINT-v1\0".utf8) + canonical(cp) }
func merkleLeaf(_ leaf: SignedLeaf) throws -> Data { Data(SHA256.hash(data: try Data([0]) + canonical(leaf))) }
func merkleParent(_ left: Data, _ right: Data) -> Data { Data(SHA256.hash(data: Data([1]) + left + right)) }
func hex(_ data: Data) -> String { data.map {String(format: "%02x", $0)}.joined() }
func unhex(_ text: String) -> Data? {
    guard text.count == 64, text.allSatisfy({"0123456789abcdef".contains($0)}) else { return nil }
    var bytes = [UInt8](); var start = text.startIndex
    while start < text.endIndex {
        let end = text.index(start, offsetBy:2)
        guard let byte = UInt8(text[start..<end],radix:16) else { return nil }
        bytes.append(byte); start = end
    }
    return Data(bytes)
}
func merkleProof(_ leaves: [Data], index: Int) -> (Data, InclusionProof) {
    precondition(!leaves.isEmpty && leaves.indices.contains(index))
    var level = leaves, position = index
    var siblings = [Sibling]()
    while level.count > 1 {
        let other = position ^ 1
        siblings.append(Sibling(side: position % 2 == 0 ? "right" : "left", hash: hex(other < level.count ? level[other] : level[position])))
        if level.count % 2 == 1 { level.append(level.last!) }
        level = stride(from:0,to:level.count,by:2).map {merkleParent(level[$0],level[$0+1])}
        position /= 2
    }
    return (level[0],InclusionProof(leafIndex:index,treeSize:leaves.count,siblings:siblings))
}

final class NativeSignedAudit {
    let directory: URL
    let runID: String
    let keyID: String
    let publicKey: Data
    private let key = Curve25519.Signing.PrivateKey()
    private let lock = NSLock()
    private var poisoned = false
    private(set) var bundles = [NativeBundle]()
    private let beforePersist: (([String:String]) throws -> Void)?
    init(directory: URL, runID: String, beforePersist: (([String:String]) throws -> Void)? = nil) throws {
        self.directory = directory; self.runID = runID; self.beforePersist = beforePersist
        publicKey = key.publicKey.rawRepresentation; keyID = sha256(publicKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:false)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Bundles"), withIntermediateDirectories:false)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("TrustExport"), withIntermediateDirectories:false)
        try exclusiveDurableWrite(publicKey,to:directory.appendingPathComponent("TrustExport/public-key.raw"))
        // Private key stays in process memory only; every fresh run has a new key.
    }
    @discardableResult func append(policy: Policy, facts: [String:String]) throws -> NativeBundle {
        lock.lock(); defer {lock.unlock()}
        guard !poisoned else { throw GateError.posix(EIO) }
        do {
            var event = facts
            event["schema"] = nativeEvidenceSchema; event["runID"] = runID
            event["keyID"] = keyID; event["eventID"] = UUID().uuidString
            event["timestamp"] = ISO8601DateFormatter().string(from:Date())
            event["policyVersion"] = String(policy.version); event["policyHash"] = sha256(try canonical(policy))
            let signature = try key.signature(for:eventMessage(event)).base64EncodedString()
            let leaf = SignedLeaf(event:event,signature:signature)
            let leaves = try bundles.map {try merkleLeaf($0.leaf)} + [merkleLeaf(leaf)]
            let (root,proof) = merkleProof(leaves,index:leaves.count-1)
            let cp = NativeCheckpoint(schema:nativeEvidenceSchema,kind:"local-file-merkle-checkpoint",id:UUID().uuidString,
                                      runID:runID,keyID:keyID,tipEventID:event["eventID"]!,root:hex(root),treeSize:leaves.count)
            let signed = SignedCheckpoint(checkpoint:cp,signature:try key.signature(for:checkpointMessage(cp)).base64EncodedString())
            let bundle = NativeBundle(schema:nativeEvidenceSchema,leaf:leaf,policy:policy,proof:proof,checkpoint:signed)
            try beforePersist?(event)
            try exclusiveDurableWrite(try canonical(signed),to:directory.appendingPathComponent("TrustExport/checkpoint-\(cp.treeSize).json"))
            try exclusiveDurableWrite(try canonical(bundle),to:directory.appendingPathComponent("Bundles/\(event["eventID"]!).json"))
            bundles.append(bundle)
            return bundle
        } catch { poisoned = true; throw error }
    }
    func snapshot() -> (NativePackage, NativeTrustSet) {
        (NativePackage(schema:nativeEvidenceSchema,runID:runID,bundles:bundles),
         NativeTrustSet(schema:nativeEvidenceSchema,runID:runID,checkpoints:bundles.map {$0.checkpoint}))
    }
    func exportRun() throws -> URL {
        lock.lock(); defer {lock.unlock()}
        guard !poisoned else {throw GateError.posix(EIO)}
        let (package,trust) = snapshot()
        let destination = directory.appendingPathComponent("run-package.json")
        try exclusiveDurableWrite(try canonical(trust),to:directory.appendingPathComponent("TrustExport/trust-set.json"))
        try exclusiveDurableWrite(try canonical(package),to:destination)
        return destination
    }
}

func verifyNative(packageData: Data, pinnedPublicKey: Data, pinnedTrustData: Data) -> NativeVerification {
    func unknown(_ reason: String) -> NativeVerification {
        NativeVerification(verdict:"indeterminate",valid:false,complete:false,reason:reason,events:[])
    }
    do {
        let package = try JSONDecoder().decode(NativePackage.self,from:packageData)
        let trust = try JSONDecoder().decode(NativeTrustSet.self,from:pinnedTrustData)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation:pinnedPublicKey)
        let keyID = sha256(pinnedPublicKey)
        guard package.schema == nativeEvidenceSchema, trust.schema == nativeEvidenceSchema,
              package.runID == trust.runID, !package.bundles.isEmpty,
              package.bundles.count == trust.checkpoints.count else {return unknown("Missing/incompatible package or pinned checkpoints")}
        var seen = Set<String>(), rows = [VerificationRow](), leaves = [Data]()
        var intents = [String:[String:String]](), linked = Set<String>()
        for (index,bundle) in package.bundles.enumerated() {
            let event = bundle.leaf.event, cp = bundle.checkpoint.checkpoint
            let required = ["eventID","requestID","runID","keyID","timestamp","schema","policyVersion","policyHash",
                            "role","subjectID","workflow","resourceID","classification","operation","destination",
                            "phase","policyDecision","decision","enforcement","brokerPID","beforeHash"]
            guard required.allSatisfy({!(event[$0] ?? "").isEmpty}),
                  UUID(uuidString:event["eventID"]!) != nil, UUID(uuidString:event["requestID"]!) != nil,
                  seen.insert(event["eventID"]!).inserted, event["schema"] == nativeEvidenceSchema,
                  bundle.schema == nativeEvidenceSchema, event["keyID"] == keyID,
                  event["runID"] == package.runID, ISO8601DateFormatter().date(from:event["timestamp"]!) != nil,
                  ["intent","result"].contains(event["phase"]!), ["allow","deny","indeterminate"].contains(event["decision"]!),
                  unhex(event["beforeHash"]!) != nil else {return unknown("Malformed native event")}
            guard let signature = Data(base64Encoded:bundle.leaf.signature),
                  key.isValidSignature(signature,for:try eventMessage(event)) else {return unknown("Invalid Ed25519 event signature")}
            try bundle.policy.validate()
            guard event["policyVersion"] == String(bundle.policy.version),
                  event["policyHash"] == sha256(try canonical(bundle.policy)) else {return unknown("Policy snapshot/version/hash mismatch")}
            let allowed = bundle.policy.allows(level:event["classification"]!,role:event["role"]!,workflow:event["workflow"]!,
                                              operation:event["operation"]!,destination:event["destination"]!)
            guard event["policyDecision"] == (allowed ? "allow" : "deny") else {return unknown("Signed policy decision inconsistent with snapshot")}
            guard try canonical(bundle.checkpoint) == canonical(trust.checkpoints[index]),
                  cp.schema == nativeEvidenceSchema, cp.kind == "local-file-merkle-checkpoint",
                  cp.keyID == keyID, cp.runID == package.runID, cp.tipEventID == event["eventID"],
                  cp.treeSize == index+1, let cpSignature = Data(base64Encoded:bundle.checkpoint.signature),
                  key.isValidSignature(cpSignature,for:try checkpointMessage(cp)) else {return unknown("Untrusted or invalid signed local checkpoint")}
            let leaf = try merkleLeaf(bundle.leaf); leaves.append(leaf)
            let (root,expected) = merkleProof(leaves,index:index)
            guard hex(root) == cp.root, try canonical(expected) == canonical(bundle.proof) else {return unknown("Merkle inclusion/order mismatch")}
            if event["enforcement"] == "broker-network" {
                let paths = ["approved-loopback":"/ingest","redirect-loopback":"/redirect"]
                guard let expectedPath = paths[event["destination"] ?? ""], let endpoint = event["endpoint"],
                      let url = URL(string:endpoint), url.scheme == "http", url.host == "127.0.0.1",
                      let port = url.port, (1024...65535).contains(port), url.path == expectedPath,
                      endpoint == "http://127.0.0.1:\(port)\(expectedPath)",
                      event["endpointHash"] == sha256(Data(endpoint.utf8)), event["redirectPolicy"] == "never",
                      event["retryPolicy"] == "never" else {return unknown("Destination ID is not bound to its exact loopback socket/path")}
            }
            if event["phase"] == "intent" {
                guard allowed, event["decision"] == "indeterminate", ["broker-filesystem","broker-network"].contains(event["enforcement"]!) else {return unknown("Invalid effect intent")}
                intents[event["eventID"]!] = event
            } else if event["enforcement"] == "network-policy" {
                guard event["operation"] == "tool_send", (!allowed || event["destinationRegistered"] == "false"),
                      event["decision"] == "deny", event["networkAttempts"] == "0", event["writeAttempts"] == "0",
                      event["deliveryStatus"] == "not-started", event["sourceReadVerified"] == "true",
                      event["beforeHash"] == event["afterHash"], bundle.policy.allows(level:event["classification"]!,role:event["role"]!,workflow:event["workflow"]!,operation:"read",destination:"file") else {return unknown("Invalid network preflight denial")}
            } else if event["enforcement"] == "worker-network-observation" {
                guard event["decision"] == "deny", ["1","13"].contains(event["connectErrno"] ?? ""),
                      event["connected"] == "false", event["observationScope"] == "this-instrumented-worker-only",
                      let pid = Int(event["workerPID"] ?? ""), pid > 0, String(pid) != event["brokerPID"] else {return unknown("Invalid network OS observation")}
            } else if event["enforcement"] == "broker-network" {
                guard allowed, event["operation"] == "tool_send", let id = event["intentEventID"], let intent = intents[id],
                      linked.insert(id).inserted, event["networkAttempts"] == "1", event["redirectPolicy"] == "never",
                      event["retryPolicy"] == "never", let endpoint = event["endpoint"], endpoint.hasPrefix("http://127.0.0.1:"),
                      event["endpointHash"] == sha256(Data(endpoint.utf8)), event["sourceReadVerified"] == "true",
                      event["beforeHash"] == event["afterHash"], event["writeAttempts"] == "0",
                      bundle.policy.allows(level:event["classification"]!,role:event["role"]!,workflow:event["workflow"]!,operation:"read",destination:"file"),
                      (event["decision"] == "allow" && event["httpStatus"] == "200" && event["deliveryStatus"] == "acknowledged") ||
                      (event["decision"] == "indeterminate" && event["deliveryStatus"] == "unknown") else {return unknown("Invalid network result")}
                for name in ["requestID","runID","role","subjectID","workflow","resourceID","classification","operation","destination","policyVersion","policyHash","beforeHash","endpoint","endpointHash","redirectPolicy","retryPolicy"] {
                    guard event[name] == intent[name] else {return unknown("Network result differs from immutable intent")}
                }
            } else if event["enforcement"] == "worker-os-observation" {
                guard event["decision"] == "deny", ["1","13"].contains(event["readErrno"] ?? ""),
                      ["1","13"].contains(event["writeErrno"] ?? ""), event["readOpened"] == "false", event["writeOpened"] == "false",
                      let workerPID = Int(event["workerPID"] ?? ""), workerPID > 0,
                      let brokerPID = Int(event["brokerPID"] ?? ""), brokerPID > 0, workerPID != brokerPID,
                      event["observationScope"] == "this-instrumented-worker-only" else {return unknown("Invalid worker-scoped OS denial observation")}
            } else if event["enforcement"] == "app-policy" {
                guard !allowed, event["decision"] == "deny", event["writeAttempts"] == "0",
                      event["beforeHash"] == event["afterHash"] else {return unknown("Invalid application policy-denial facts")}
            } else if event["enforcement"] == "broker-filesystem" && event["decision"] == "allow" {
                guard allowed, let intentID = event["intentEventID"], let intent = intents[intentID], linked.insert(intentID).inserted,
                      event["writeAttempts"] == "1", event["readbackVerified"] == "true", event["markerCount"] == "1",
                      event["afterHash"] != event["beforeHash"], unhex(event["afterHash"] ?? "") != nil else {return unknown("Missing intent or invalid write/readback facts")}
                for name in ["requestID","runID","role","subjectID","workflow","resourceID","classification","operation","destination","policyVersion","policyHash","beforeHash"] {
                    guard event[name] == intent[name] else {return unknown("Result differs from linked immutable intent")}
                }
            } else if event["decision"] != "indeterminate" {return unknown("Unknown enforcement/result combination")}
            rows.append(VerificationRow(eventID:event["eventID"]!,requestID:event["requestID"]!,phase:event["phase"]!,
                                        enforcement:event["enforcement"]!,resourceID:event["resourceID"]!,decision:event["decision"]!))
        }
        let complete = Set(intents.keys) == linked && !rows.contains {$0.phase == "result" && $0.decision == "indeterminate"}
        return NativeVerification(verdict:complete ? "verified-records" : "indeterminate",valid:true,complete:complete,
            reason:complete ? "Ed25519 signatures and ordered Merkle inclusion verified against separately supplied local pins; facts attest broker observations, not external truth or a permissioned chain" : "Authentic partial records; execution result remains unestablished",events:rows)
    } catch {return unknown("Missing, malformed or incompatible evidence/trust material")}
}

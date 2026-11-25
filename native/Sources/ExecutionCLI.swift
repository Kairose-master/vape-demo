// Official explicit synthetic CLI entry point. This process is NOT App Sandbox.
import Foundation
import Darwin
@main enum ExecutionCLI {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {exit(64)}
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),runID=CommandLine.arguments[2]
        guard UUID(uuidString:runID) != nil else {exit(64)}
        let policy=try JSONDecoder().decode(Policy.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
        try policy.validate()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        var resources=[Resource]()
        for level in ["L2","L3"] {
            let data=Data("[SYNTHETIC NATIVE ANCHOR TEST] \(level)\n".utf8),name=level+".txt"
            try exclusiveDurableWrite(data,to:folder.appendingPathComponent(name))
            resources.append(Resource(id:level,level:level,fileName:name,initialSHA256:sha256(data)))
        }
        let fixture=Fixture(folder:folder.path,resources:resources)
        try exclusiveDurableWrite(try canonical(fixture),to:folder.appendingPathComponent("fixture.json"))
        let audit=try NativeSignedAudit(directory:folder.appendingPathComponent("SignedEvidence"),runID:runID)
        print(String(decoding:try canonical(["status":"KEY_READY","runID":runID,"keyID":audit.keyID,"producerPID":String(getpid()),"policyHash":sha256(try canonical(policy))]),as:UTF8.self));fflush(stdout)
        // The controller acquires a separate public-key pin BEFORE authorizing this fresh execution.
        guard readLine() == "PINNED" else {exit(2)}
        let gate=try FileGate(folder:folder,fixture:fixture,policy:policy)
        let denied=executeSignedWrite(gate:gate,audit:audit,resourceID:"L2",context:BrokerContext(role:"operator",workflow:"approved-cloud-read"))
        guard denied.decision == "deny" else {exit(2)}
        let written=executeSignedWrite(gate:gate,audit:audit,resourceID:"L3",context:BrokerContext(role:"operator",workflow:"approved-workflow"))
        guard written.decision == "allow",gate.writeAttempts == 1 else {exit(2)}
        let package=try audit.exportRun()
        print(String(decoding:try canonical(["status":"EXECUTED","package":package.path,"L2":"deny","L3":"allow","writeAttempts":"1","scope":"explicit-unsandboxed-native-cli"]),as:UTF8.self))
    }
}

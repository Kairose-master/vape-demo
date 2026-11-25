import Foundation
import Darwin
@main enum CoreTests {
    static func main() throws {
        let policyURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: policyURL))
        try policy.validate()
        var assertions = 0
        func check(_ truth: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try truth() else { fatalError("FAIL: \(name)") }
            assertions += 1
        }
        try check(!policy.allows(level:"L1",role:"operator",workflow:"local-only",operation:"model_send",destination:"approved-cloud"),"L1 cloud denied")
        try check(policy.allows(level:"L1",role:"operator",workflow:"local-only",operation:"model_send",destination:"local-model"),"L1 local allowed")
        try check(!policy.allows(level:"L2",role:"operator",workflow:"approved-cloud-read",operation:"write",destination:"file"),"L2 write denied")
        try check(policy.allows(level:"L3",role:"operator",workflow:"approved-workflow",operation:"write",destination:"file"),"L3 write allowed")
        for level in policy.levels {
            try check(!policy.allows(level:level,role:"operator",workflow:"approved-workflow",operation:"tool_send",destination:"approved-tool"),"tool export separately denied")
        }
        try check(!policy.allows(level:"L3",role:"worker-supplied-role",workflow:"approved-workflow",operation:"write",destination:"file"),"unknown role denied")
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let initial = Data("[SYNTHETIC UNIT TEST ONLY]\n".utf8)
        var resources: [Resource] = []
        for level in ["L2","L3"] {
            let name = level.lowercased()+"-contract.txt"
            try initial.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            resources.append(Resource(id:"contract-"+level,level:level,fileName:name,initialSHA256:sha256(initial)))
        }
        let fixture = Fixture(folder:root.path,resources:resources)
        let gate = try FileGate(folder:root,fixture:fixture,policy:policy)
        let l2 = BrokerContext(role:"operator",workflow:"approved-cloud-read")
        let l3 = BrokerContext(role:"operator",workflow:"approved-workflow")
        var l2Intent = false
        do {
            try gate.appendSynthetic(id:"contract-L2",context:l2) { l2Intent = true }
            fatalError("L2 write incorrectly succeeded")
        } catch GateError.denied { }
        try check(!l2Intent && gate.writeAttempts == 0,"L2 blocked before intent/open")
        try check(try gate.read(id:"contract-L2",context:l2) == initial,"L2 unchanged")
        do {
            try gate.appendSynthetic(id:"contract-L3",context:l3) { throw GateError.invalidPolicy }
            fatalError("Failed intent incorrectly proceeded")
        } catch GateError.invalidPolicy { }
        try check(gate.writeAttempts == 0,"failed intent blocks write open")
        try check(try gate.read(id:"contract-L3",context:l3) == initial,"failed intent leaves actual file unchanged")
        let evidence = try NativeEvidence(folder:root)
        try gate.appendSynthetic(id:"contract-L3",context:l3) { try evidence.append(["phase":"intent","resourceID":"contract-L3"]) }
        let changed = try gate.read(id:"contract-L3",context:l3)
        try check(changed.count > initial.count && changed.starts(with:initial),"L3 actual OS append and readback")
        try check(try Data(contentsOf:root.appendingPathComponent("l3-contract.txt")) == changed,"independent actual file read matches")
        try check(gate.writeAttempts == 1,"one write attempt only")
        do { _ = try gate.read(id:"../unregistered",context:l3); fatalError("Unknown resource accepted") }
        catch GateError.unknownResource { assertions += 1 }
        let renamed = try JSONDecoder().decode(Policy.self, from: Data(String(decoding:Data(contentsOf:policyURL),as:UTF8.self).replacingOccurrences(of:"L3",with:"org-custom-blue").utf8))
        try check(renamed.allows(level:"org-custom-blue",role:"operator",workflow:"approved-workflow",operation:"write",destination:"file"),"organization labels editable")
        print("PASS \(assertions) native policy/file checks. UNSANDBOXED unit executable; NOT evidence of App Sandbox denial.")
    }
}

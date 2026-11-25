import Foundation
import Darwin
struct NativeExecutionResult {
    let decision: String
    let effectStatus: String
    let reason: String
    let intentID: String?
    let resultID: String?
}
func nativeFacts(resource: Resource, context: BrokerContext, requestID: String, before: Data) -> [String:String] {
    ["requestID":requestID,"role":context.role,"subjectID":"uid:\(geteuid())","workflow":context.workflow,
     "resourceID":resource.id,"classification":resource.level,"operation":"write","destination":"file",
     "brokerPID":String(getpid()),"beforeHash":sha256(before)]
}
func executeSignedWrite(gate: FileGate, audit: NativeSignedAudit, resourceID: String, context: BrokerContext) -> NativeExecutionResult {
    var intentID: String?
    let startAttempts = gate.writeAttempts
    var applied = false
    do {
        let resource = try gate.resource(resourceID)
        let before = try gate.read(id:resourceID,context:context)
        var facts = nativeFacts(resource:resource,context:context,requestID:UUID().uuidString,before:before)
        let allowed = gate.policy.allows(level:resource.level,role:context.role,workflow:context.workflow,operation:"write",destination:"file")
        facts["policyDecision"] = allowed ? "allow" : "deny"
        if !allowed {
            var unexpectedIntent = false
            do {
                try gate.appendSynthetic(id:resourceID,context:context) { unexpectedIntent = true; throw GateError.invalidPolicy }
                throw GateError.unsafeFile
            } catch GateError.denied { }
            let after = try gate.read(id:resourceID,context:context)
            guard !unexpectedIntent, gate.writeAttempts == startAttempts, after == before else {throw GateError.unsafeFile}
            facts.merge(["phase":"result","decision":"deny","enforcement":"app-policy","writeAttempts":"0","afterHash":sha256(after)]) {_,new in new}
            let bundle = try audit.append(policy:gate.policy,facts:facts)
            return NativeExecutionResult(decision:"deny",effectStatus:"not-started",reason:"APP_POLICY_DENY; file unchanged; write open attempts 0",intentID:nil,resultID:bundle.leaf.event["eventID"])
        }
        facts.merge(["phase":"intent","decision":"indeterminate","enforcement":"broker-filesystem"]) {_,new in new}
        try gate.appendSynthetic(id:resourceID,context:context) {
            intentID = try audit.append(policy:gate.policy,facts:facts).leaf.event["eventID"]
        }
        applied = true
        let after = try gate.read(id:resourceID,context:context)
        let markerCount = String(decoding:after,as:UTF8.self).components(separatedBy:"[SYNTHETIC VAPE L3 WRITE").count-1
        guard after.starts(with:before),after.count > before.count,markerCount == 1,gate.writeAttempts-startAttempts == 1 else {throw GateError.unsafeFile}
        facts.merge(["phase":"result","decision":"allow","intentEventID":intentID!,"writeAttempts":"1", "afterHash":sha256(after),
                     "readbackVerified":"true","markerCount":String(markerCount)]) {_,new in new}
        let bundle = try audit.append(policy:gate.policy,facts:facts)
        return NativeExecutionResult(decision:"allow",effectStatus:"completed",reason:"Actual append/fsync/readback; signed result committed",intentID:intentID,resultID:bundle.leaf.event["eventID"])
    } catch {
        return NativeExecutionResult(decision:"indeterminate",effectStatus:applied ? "completed" : (gate.writeAttempts > startAttempts ? "unknown" : "not-started"),
                                     reason:"Evidence or execution failure; no automatic retry",intentID:intentID,resultID:nil)
    }
}

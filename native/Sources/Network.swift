import Foundation
final class NetworkGate {
    let files: FileGate; let audit: NativeSignedAudit; let port: Int
    private(set) var attempts = 0
    private var used = Set<String>()
    init(files: FileGate,audit: NativeSignedAudit,port: Int) {self.files=files;self.audit=audit;self.port=port}
    func send(resourceID: String, context: BrokerContext, destination: String, requestID: String = UUID().uuidString) -> NativeExecutionResult {
        guard used.insert(requestID).inserted else {return NativeExecutionResult(decision:"indeterminate",effectStatus:"unknown",reason:"Duplicate request; no retry",intentID:nil,resultID:nil)}
        var intentID: String?, started = false
        do {
            let resource = try files.resource(resourceID), data = try files.read(id:resourceID,context:context)
            var facts = nativeFacts(resource:resource,context:context,requestID:requestID,before:data)
            facts.merge(["operation":"tool_send","destination":destination,"sourceReadVerified":"true","writeAttempts":"0","afterHash":sha256(data),"redirectPolicy":"never","retryPolicy":"never"]) {_,new in new}
            let allowed = files.policy.allows(level:resource.level,role:context.role,workflow:context.workflow,operation:"tool_send",destination:destination)
            facts["policyDecision"] = allowed ? "allow" : "deny"
            // Registry lookup is fixed and internal. No caller-supplied URL is accepted.
            let endpoint: LoopbackEndpoint? = destination == "approved-loopback" ? LoopbackEndpoint(port:port,path:"/ingest") : destination == "redirect-loopback" ? LoopbackEndpoint(port:port,path:"/redirect") : nil
            guard allowed, let endpoint = endpoint else {
                facts.merge(["phase":"result","decision":"deny","enforcement":"network-policy","networkAttempts":"0","deliveryStatus":"not-started","destinationRegistered":endpoint == nil ? "false":"true"]) {_,new in new}
                let result = try audit.append(policy:files.policy,facts:facts)
                return NativeExecutionResult(decision:"deny",effectStatus:"not-started",reason:"Policy/registry deny before socket; read succeeded",intentID:nil,resultID:result.leaf.event["eventID"])
            }
            try endpoint.validate()
            facts.merge(["phase":"intent","decision":"indeterminate","enforcement":"broker-network","endpoint":endpoint.identity,"endpointHash":sha256(Data(endpoint.identity.utf8)),"networkAttempts":"0","deliveryStatus":"not-started"]) {_,new in new}
            intentID = try audit.append(policy:files.policy,facts:facts).leaf.event["eventID"]
            attempts += 1; started = true
            let status = try postOnce(endpoint:endpoint,requestID:requestID,content:data)
            facts.merge(["phase":"result","decision":status == 200 ? "allow":"indeterminate","intentEventID":intentID!,"networkAttempts":"1","httpStatus":String(status),"deliveryStatus":status == 200 ? "acknowledged":"unknown"]) {_,new in new}
            let result = try audit.append(policy:files.policy,facts:facts)
            return NativeExecutionResult(decision:status == 200 ? "allow":"indeterminate",effectStatus:status == 200 ? "completed":"unknown",reason:"HTTP \(status); no redirect or retry",intentID:intentID,resultID:result.leaf.event["eventID"])
        } catch {
            return NativeExecutionResult(decision:"indeterminate",effectStatus:started ? "unknown":"not-started",reason:"Execution/evidence failed; no automatic retry",intentID:intentID,resultID:nil)
        }
    }
}

import Foundation
import CryptoKit
@main enum SignedAuditTests {
    static func main() throws {
        let policy = try JSONDecoder().decode(Policy.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let root = URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool,_ message:String) throws {
            guard try value() else {fatalError("FAIL: "+message)}; count += 1
        }
        func session(_ suffix:String, fault: (([String:String])throws->Void)? = nil) throws -> (FileGate,NativeSignedAudit,URL) {
            let folder = root.appendingPathComponent(suffix)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            let bytes = Data("[SYNTHETIC UNIT AUDIT]\n".utf8)
            var resources = [Resource]()
            for level in ["L2","L3"] {
                let name=level.lowercased()+".txt"; try exclusiveDurableWrite(bytes,to:folder.appendingPathComponent(name))
                resources.append(Resource(id:"contract-"+level,level:level,fileName:name,initialSHA256:sha256(bytes)))
            }
            return (try FileGate(folder:folder,fixture:Fixture(folder:folder.path,resources:resources),policy:policy),
                    try NativeSignedAudit(directory:folder.appendingPathComponent("Audit"),runID:UUID().uuidString,beforePersist:fault),folder)
        }
        let l2=BrokerContext(role:"operator",workflow:"approved-cloud-read"),l3=BrokerContext(role:"operator",workflow:"approved-workflow")
        let (gate,audit,_) = try session("normal")
        // Synthetic unit observation only; actual worker observations are verified in the live app separately.
        var worker=nativeFacts(resource:try gate.resource("contract-L3"),context:l3,requestID:UUID().uuidString,before:try gate.read(id:"contract-L3",context:l3))
        worker.merge(["phase":"result","decision":"deny","policyDecision":"allow","enforcement":"worker-os-observation","workerPID":"999999",
                      "readErrno":"1","writeErrno":"1","readOpened":"false","writeOpened":"false","observationScope":"this-instrumented-worker-only"]) {_,new in new}
        try audit.append(policy:policy,facts:worker)
        let denied=executeSignedWrite(gate:gate,audit:audit,resourceID:"contract-L2",context:l2)
        try check(denied.decision=="deny" && gate.writeAttempts==0,"L2 no write before signature")
        let allowed=executeSignedWrite(gate:gate,audit:audit,resourceID:"contract-L3",context:l3)
        try check(allowed.decision=="allow" && gate.writeAttempts==1,"L3 exact one real write")
        let (package,trust)=audit.snapshot()
        let data=try canonical(package), pins=try canonical(trust)
        let valid=verifyNative(packageData:data,pinnedPublicKey:audit.publicKey,pinnedTrustData:pins)
        try check(valid.valid && valid.complete && valid.events.count==4,"full signed sequence")
        try check(valid.events.map {$0.decision} == ["deny","deny","indeterminate","allow"],"three distinct result types and intent")
        _ = try audit.exportRun()
        try check(!String(decoding:data,as:UTF8.self).contains("SYNTHETIC UNIT AUDIT"),"no raw document")
        func bad(_ value:Data,_ name:String,key:Data?=nil,trustData:Data?=nil) throws {
            let result=verifyNative(packageData:value,pinnedPublicKey:key ?? audit.publicKey,pinnedTrustData:trustData ?? pins)
            try check(!result.valid && result.verdict=="indeterminate",name)
        }
        func mutate(_ transform:(inout [String:Any])->Void) throws -> Data {
            var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            transform(&object); return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        }
        func changedBundle(_ index:Int,_ transform:(inout [String:Any])->Void) throws -> Data {
            try mutate {object in var bundles=object["bundles"] as! [[String:Any]]; transform(&bundles[index]); object["bundles"]=bundles}
        }
        try bad(Data("{}".utf8),"missing evidence")
        try bad(data,"wrong separately pinned key",key:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        try bad(data,"missing checkpoints",trustData:Data("{}".utf8))
        try bad(try mutate {$0["schema"]="legacy-HMAC"},"formats never mixed")
        try bad(try mutate {var b=$0["bundles"] as! [Any];b.remove(at:2);$0["bundles"]=b},"missing intent")
        try bad(try mutate {var b=$0["bundles"] as! [Any];b.removeLast();$0["bundles"]=b},"missing result")
        try bad(try changedBundle(3){var leaf=$0["leaf"] as! [String:Any];var event=leaf["event"] as! [String:String];event["decision"]="deny";leaf["event"]=event;$0["leaf"]=leaf},"tampered execution decision")
        try bad(try changedBundle(3){var leaf=$0["leaf"] as! [String:Any];leaf["signature"]=Data(repeating:0,count:64).base64EncodedString();$0["leaf"]=leaf},"bad signature")
        try bad(try changedBundle(3){var p=$0["policy"] as! [String:Any];p["version"]=99;$0["policy"]=p},"policy snapshot tamper")
        try bad(try changedBundle(2){var proof=$0["proof"] as! [String:Any];proof["siblings"]=[];$0["proof"]=proof},"incomplete odd-tree proof")
        try bad(try changedBundle(2){var proof=$0["proof"] as! [String:Any];proof["leafIndex"]=0;$0["proof"]=proof},"wrong inclusion index")
        try bad(try changedBundle(3){var signed=$0["checkpoint"] as! [String:Any];var cp=signed["checkpoint"] as! [String:Any];cp["root"]=String(repeating:"0",count:64);signed["checkpoint"]=cp;$0["checkpoint"]=signed},"checkpoint tamper")
        try audit.append(policy:policy,facts:worker)
        try check(verifyNative(packageData:data,pinnedPublicKey:audit.publicKey,pinnedTrustData:pins).valid,"old signed package and pins remain valid after append")
        let (preGate,preAudit,_)=try session("intent-failure",fault:{if $0["phase"]=="intent" {throw GateError.posix(5)}})
        let pre=executeSignedWrite(gate:preGate,audit:preAudit,resourceID:"contract-L3",context:l3)
        try check(pre.decision=="indeterminate" && pre.effectStatus=="not-started" && preGate.writeAttempts==0,"intent failure closes before write")
        try check(String(decoding:try preGate.read(id:"contract-L3",context:l3),as:UTF8.self)=="[SYNTHETIC UNIT AUDIT]\n","intent failure file unchanged")
        let (postGate,postAudit,_)=try session("result-failure",fault:{if $0["phase"]=="result" {throw GateError.posix(5)}})
        let post=executeSignedWrite(gate:postGate,audit:postAudit,resourceID:"contract-L3",context:l3)
        try check(post.decision=="indeterminate" && post.effectStatus=="completed" && postGate.writeAttempts==1,"post-write evidence failure is not denial")
        let (partial,partialTrust)=postAudit.snapshot()
        let result=verifyNative(packageData:try canonical(partial),pinnedPublicKey:postAudit.publicKey,pinnedTrustData:try canonical(partialTrust))
        try check(result.valid && !result.complete && result.verdict=="indeterminate","signed intent without result remains indeterminate")
        _ = executeSignedWrite(gate:postGate,audit:postAudit,resourceID:"contract-L3",context:l3)
        try check(postGate.writeAttempts==1,"poisoned audit never causes second write")
        print("PASS \(count) native Ed25519/Merkle and failure-boundary checks. Unit worker facts are synthetic; live OS evidence must be verified separately.")
    }
}

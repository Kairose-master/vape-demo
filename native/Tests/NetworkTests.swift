import Foundation
import Darwin
@main enum NetworkTests {
 static func main() throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]), port=Int(CommandLine.arguments[2])!
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    let base=try JSONDecoder().decode(Policy.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
    let extra=["approved-loopback","redirect-loopback","missing-registry"].map {Rule(level:"L3",role:"operator",workflow:"approved-workflow",operation:"tool_send",destination:$0,effect:"allow")}
    let policy=Policy(version:2,organization:base.organization,levels:base.levels,defaultEffect:"deny",rules:base.rules+extra)
    var resources=[Resource]()
    for level in ["L2","L3"] {
        let data=Data("SYNTHETIC-NETWORK-TEST-\(level)\n".utf8),name=level+".txt"
        try exclusiveDurableWrite(data,to:root.appendingPathComponent(name))
        resources.append(Resource(id:level,level:level,fileName:name,initialSHA256:sha256(data)))
    }
    let fixture=Fixture(folder:root.path,resources:resources), gate=try FileGate(folder:root,fixture:fixture,policy:policy)
    let l2=BrokerContext(role:"operator",workflow:"approved-cloud-read"),l3=BrokerContext(role:"operator",workflow:"approved-workflow")
    var checks=0
    func check(_ ok:Bool,_ name:String) {precondition(ok,name);checks += 1}
    let audit=try NativeSignedAudit(directory:root.appendingPathComponent("normal"),runID:UUID().uuidString)
    let net=NetworkGate(files:gate,audit:audit,port:port)
    check(try gate.read(id:"L2",context:l2).count>0,"L2 approved read")
    check(net.send(resourceID:"L2",context:l2,destination:"unregistered-external").decision=="deny" && net.attempts==0,"Unknown destination denied before socket")
    check(net.send(resourceID:"L2",context:l2,destination:"approved-loopback").decision=="deny" && net.attempts==0,"Registered destination does not imply permission")
    check(net.send(resourceID:"L3",context:l3,destination:"missing-registry").decision=="deny" && net.attempts==0,"Explicit allow cannot bypass missing registry")
    try exclusiveDurableWrite(try canonical(["networkAttempts":"0","sourceReadSucceeded":"true"]),to:root.appendingPathComponent("ready-zero.json"))
    var waits = 0
    while !FileManager.default.fileExists(atPath:root.appendingPathComponent("receiver-zero.json").path) {
        usleep(100000); waits += 1; if waits > 100 {throw GateError.posix(ETIMEDOUT)}
    }
    let id=UUID().uuidString, sent=net.send(resourceID:"L3",context:l3,destination:"approved-loopback",requestID:id)
    check(sent.decision=="allow" && net.attempts==1,"Real loopback HTTP acknowledged")
    check(net.send(resourceID:"L3",context:l3,destination:"approved-loopback",requestID:id).decision=="indeterminate" && net.attempts==1,"No duplicate retransmission")
    let package=try audit.exportRun(), snapshot=audit.snapshot()
    let verified=verifyNative(packageData:try Data(contentsOf:package),pinnedPublicKey:audit.publicKey,pinnedTrustData:try canonical(snapshot.1))
    check(verified.valid && verified.complete,"Independent-signature algorithm with network semantics")
    let failIntent=try NativeSignedAudit(directory:root.appendingPathComponent("intent-fail"),runID:UUID().uuidString,beforePersist:{event in if event["phase"]=="intent" {throw GateError.posix(EIO)}})
    let pre=NetworkGate(files:gate,audit:failIntent,port:port)
    let preResult=pre.send(resourceID:"L3",context:l3,destination:"approved-loopback")
    check(preResult.decision=="indeterminate" && preResult.effectStatus=="not-started" && pre.attempts==0,"Intent failure before socket")
    let failResult=try NativeSignedAudit(directory:root.appendingPathComponent("result-fail"),runID:UUID().uuidString,beforePersist:{event in if event["phase"]=="result" {throw GateError.posix(EIO)}})
    let post=NetworkGate(files:gate,audit:failResult,port:port)
    let postResult=post.send(resourceID:"L3",context:l3,destination:"approved-loopback")
    check(postResult.decision=="indeterminate" && postResult.effectStatus=="unknown" && post.attempts==1,"Received but evidence failed is not blocked")
    let partial=failResult.snapshot()
    check(!verifyNative(packageData:try canonical(partial.0),pinnedPublicKey:failResult.publicKey,pinnedTrustData:try canonical(partial.1)).complete,"Missing result indeterminate")
    let redirectAudit=try NativeSignedAudit(directory:root.appendingPathComponent("redirect"),runID:UUID().uuidString)
    let redirect=NetworkGate(files:gate,audit:redirectAudit,port:port)
    check(redirect.send(resourceID:"L3",context:l3,destination:"redirect-loopback").decision=="indeterminate" && redirect.attempts==1,"302 never followed")
    let redirected=redirectAudit.snapshot()
    let verdict=verifyNative(packageData:try canonical(redirected.0),pinnedPublicKey:redirectAudit.publicKey,pinnedTrustData:try canonical(redirected.1))
    check(verdict.valid && !verdict.complete,"Signed redirect remains indeterminate")
    check(gate.writeAttempts==0,"All source files read only")
    for resource in resources {check(sha256(try Data(contentsOf:root.appendingPathComponent(resource.fileName)))==resource.initialSHA256,"Source unchanged")}
    try exclusiveDurableWrite(try canonical(["checks":String(checks),"successfulRequestID":id,"expectedReceiverPosts":"3","sandbox":"not sandboxed; no OS-denial claim"]),to:root.appendingPathComponent("tests.json"))
    print("PASS \(checks) real loopback policy/failure checks; UNSANDBOXED CLI, not OS denial evidence")
 }
}

import Foundation
import CryptoKit
import Darwin

// V1 demo policy: the same immutable snapshot drives the actual registry gate.
enum UnifiedPolicy {
 static let value:[String:Any] = ["schema":"vape-unified-policy-v1","version":1,"principal":"native-selected-user","action":"model_send","localAlias":"local","cloudAlias":"cloud","cloudMinimumLevel":2,"default":"deny","dispatch":"apple-system-on-device-only","write":false,"tools":false]
 static var snapshot:ClassificationPolicySnapshot { ClassificationPolicySnapshot(version:1,permits:{i in i.principal.id == "native-selected-user" && i.action == "model_send" && (i.modelAlias == "local" || (i.modelAlias == "cloud" && i.resource.level != .one))}) }
}
func canonical(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
func merkle(_ leaves:[Data])->String {
 var layer=leaves.map{Data(SHA256.hash(data:Data([0])+$0))}
 guard !layer.isEmpty else{return digest(Data())}
 while layer.count>1 {var next=[Data]();for i in stride(from:0,to:layer.count,by:2){next.append(Data(SHA256.hash(data:Data([1])+layer[i]+layer[min(i+1,layer.count-1)])))};layer=next}
 return layer[0].map{String(format:"%02x",$0)}.joined()
}
// No plaintext, filenames, paths, model outputs, or credential fields in this protocol.
final class UnifiedEvidence {
 let directory:URL;let runID=UUID().uuidString
 private let key=Curve25519.Signing.PrivateKey();private var events=[[String:String]]();private var selected:RegisteredFile?
 init(_ directory:URL)throws {
  self.directory=directory
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
  try save(["runID":runID,"publicKey":key.publicKey.rawRepresentation.base64EncodedString()],"identity.json")
 }
 private func save(_ value:Any,_ name:String)throws {
  let data=try canonical(value),url=directory.appendingPathComponent(".pending-"+UUID().uuidString)
  let destination=directory.appendingPathComponent(name)
  defer{try? FileManager.default.removeItem(at:url)}
  let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
  guard fd>=0 else{throw HandoffError.intentFailed};defer{Darwin.close(fd)}
  try data.withUnsafeBytes{p in var n=0;while n<p.count{let written=Darwin.write(fd,p.baseAddress!.advanced(by:n),p.count-n);guard written>0 else{throw HandoffError.intentFailed};n+=written}}
  guard fsync(fd)==0,link(url.path,destination.path)==0 else{throw HandoffError.intentFailed}
  let parent=Darwin.open(directory.path,O_RDONLY|O_DIRECTORY);guard parent>=0 else{throw HandoffError.intentFailed};defer{Darwin.close(parent)};guard fsync(parent)==0 else{throw HandoffError.intentFailed}
 }
 var ready:Bool {guard let data=try? Data(contentsOf:directory.appendingPathComponent("ready.json")),let obj=try? JSONSerialization.jsonObject(with:data) as? [String:String] else{return false};return obj["runID"] == runID}
 func begin(_ file:RegisteredFile)throws {
  guard selected == nil,ready,file.level == .one,file.policy_version == 1 else{throw HandoffError.approvalMissing}
  selected=file
  try save(try envelope(["kind":"plan","runID":runID,"resourceID":file.resource_id.uuidString,"revision":file.classification_revision,"policyVersion":1,"policyHash":digest(try canonical(UnifiedPolicy.value)),"level":1]),"plan.json")
 }
 private func envelope(_ obj:Any)throws->[String:String] {let data=try canonical(obj);return ["metadata":data.base64EncodedString(),"signature":try key.signature(for:data).base64EncodedString()]}
 func append(_ r:HandoffAuditRecord)throws {
  guard let f=selected else{return} // Other buttons retain their original independent audit.
  guard f.resource_id == r.resourceID,f.classification_revision == r.revision,f.policy_version == r.policyVersion else{throw HandoffError.intentFailed}
  let e=try envelope(["kind":"event","runID":runID,"requestID":r.requestID.uuidString,"resourceID":r.resourceID.uuidString,"revision":r.revision,"policyVersion":r.policyVersion,"policyHash":digest(try canonical(UnifiedPolicy.value)),"principal":"native-selected-user","action":"model_send","route":r.route.rawValue,"model":r.model,"destination":r.destinationID,"phase":r.phase,"decision":r.decision,"delivery":r.delivery,"timestamp":ISO8601DateFormatter().string(from:Date())])
  try save(e,"event-\(events.count).json");events.append(e)
 }
 func finish()throws {
  guard selected != nil,events.count == 3 else{throw HandoffError.uncertain}
  let plan=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("plan.json")))
  let leaves=try ([plan]+events.map{$0 as Any}).map{try canonical($0)}
  let checkpoint=try envelope(["kind":"checkpoint","runID":runID,"count":4,"executionRoot":merkle(leaves),"policyRoot":merkle([try canonical(UnifiedPolicy.value)])])
  try save(["policy":UnifiedPolicy.value,"plan":plan,"events":events,"checkpoint":checkpoint],"package.json")
 }
}

// Shared actual entry point for the GUI and isolated headless integration check.
func executeUnifiedDemo(_ file:RegisteredFile,_ evidence:UnifiedEvidence,_ handoff:PrivateModelHandoff)throws->(PrivateModelResult,PrivateModelResult) {
 try evidence.begin(file)
 let cloud=handoff.execute(resource:file,route:.cloud)
 guard cloud.decision == "deny",cloud.delivery == "not-started" else{throw HandoffError.uncertain}
 let local=handoff.execute(resource:file,route:.local)
 guard local.decision == "allow",local.delivery == "received" else{throw HandoffError.uncertain}
 try evidence.finish()
 return (cloud,local)
}

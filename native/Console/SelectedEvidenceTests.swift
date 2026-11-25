import Foundation
import CryptoKit
@main enum SelectedEvidenceTests {
 static func main()throws {
  let key=Curve25519.Signing.PrivateKey(),publicKey=key.publicKey.rawRepresentation.base64EncodedString(),run=UUID().uuidString
  var metadata=[[String:Any]]()
  for (phase,decision,delivery) in [("policy","allow","not-started"),("intent","indeterminate","not-started"),("result","allow","received")] {
   metadata.append(["schema":1,"runID":run,"resourceID":"4894F932-ECAF-4D92-AF3F-D53CE1067FDF","revision":2,"policyVersion":1,"level":1,"binding":String(repeating:"a",count:64),"phase":phase,"decision":decision,"delivery":delivery,"cloudPolicy":"deny-no-send","model":"apple-system-default","externalCalls":0,"reason":phase=="result" ? "completed":"pending"])
  }
  func package(_ values:[[String:Any]])throws->[String:Any]{["runID":run,"events":try values.map{try SelectedEvidence.envelope($0,key:key)}]}
  let good=try package(metadata),roots=try SelectedEvidence.verify(good,publicKey:publicKey)
  precondition(roots["revision"] as? Int==2 && roots["externalCalls"] as? Int==0)
  var count=1
  func rejects(_ p:[String:Any],_ pin:String?=nil){do{_ = try SelectedEvidence.verify(p,publicKey:pin ?? publicKey);fatalError("Invalid evidence accepted")}catch{count+=1}}
  rejects(try package(Array(metadata.dropLast())))
  rejects(try package(metadata.reversed()))
  for (field,value) in [("revision",3 as Any),("resourceID",UUID().uuidString as Any),("runID",UUID().uuidString as Any),("binding",String(repeating:"b",count:64) as Any),("delivery","unknown" as Any),("decision","deny" as Any),("externalCalls",1 as Any),("prompt","SYNTHETIC PRIVATE TEXT" as Any),("model","other" as Any)] {
   var changed=metadata;changed[2][field]=value;rejects(try package(changed))
  }
  var bad=good;var events=good["events"] as! [[String:String]];events[1]["signature"]="AA==";bad["events"]=events;rejects(bad)
  rejects(good,Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
  for grade in [2,3] {var changed=metadata;for i in changed.indices{changed[i]["level"]=grade;changed[i]["cloudPolicy"]=grade==2 ? "approval-required-no-send":"deny-no-send"};_ = try SelectedEvidence.verify(package(changed),publicKey:publicKey);count+=1}
  for grade in [1,2,3] {var changed=metadata;for i in changed.indices{changed[i]["level"]=grade;changed[i]["policyVersion"]=2;changed[i]["cloudPolicy"]=grade==1 ? "deny-no-send":"approval-required-no-send"};let v2=try SelectedEvidence.verify(package(changed),publicKey:publicKey);precondition(v2["policyVersion"] as? Int==2);count+=1}
  var mixed=metadata;mixed[2]["policyVersion"]=2;rejects(try package(mixed))
  var failed=metadata;failed[2]["decision"]="indeterminate";failed[2]["delivery"]="unknown";failed[2]["reason"]="appleGuardrail"
  let failure=try SelectedEvidence.verify(package(failed),publicKey:publicKey);precondition(failure["localDecision"] as? String=="indeterminate");count+=1
  print("PASS selected signed evidence: \(count) assertions; synthetic only; no model or chain calls")
 }
}

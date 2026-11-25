import Foundation
import CryptoKit
@main enum VerifyUnified {
 static func main(){do{try verify()}catch{print("{\"status\":\"indeterminate\"}");exit(1)}}
 static func verify()throws {
  let a=CommandLine.arguments;guard a.count==4 else{throw HandoffError.uncertain}
  let raw=try Data(contentsOf:URL(fileURLWithPath:a[1]));guard raw.count<65536 else{throw HandoffError.uncertain}
  guard let package=try JSONSerialization.jsonObject(with:raw) as? [String:Any] else{throw HandoffError.uncertain}
  guard Set(package.keys)==Set(["policy","plan","events","checkpoint"]),let keyData=Data(base64Encoded:a[2]) else{throw HandoffError.uncertain}
  let key=try Curve25519.Signing.PublicKey(rawRepresentation:keyData)
  func signed(_ x:Any)throws->[String:Any] {
   guard let e=x as? [String:String],Set(e.keys)==Set(["metadata","signature"]),let d=Data(base64Encoded:e["metadata"]!),let s=Data(base64Encoded:e["signature"]!),key.isValidSignature(s,for:d),let obj=try JSONSerialization.jsonObject(with:d) as? [String:Any],obj["runID"] as? String == a[3] else{throw HandoffError.uncertain};return obj
  }
  guard try canonical(package["policy"]!) == canonical(UnifiedPolicy.value) else{throw HandoffError.uncertain}
  let plan=try signed(package["plan"]!);guard Set(plan.keys)==Set(["kind","runID","resourceID","revision","policyVersion","policyHash","level"]) else{throw HandoffError.uncertain};let hash=digest(try canonical(UnifiedPolicy.value))
  guard plan["kind"] as? String == "plan",plan["level"] as? Int == 1,plan["policyVersion"] as? Int == 1,plan["policyHash"] as? String == hash,let id=plan["resourceID"] as? String,UUID(uuidString:id) != nil,let rev=plan["revision"] as? Int,rev>0,let envelopes=package["events"] as? [[String:String]],envelopes.count == 3 else{throw HandoffError.uncertain}
  let events=try envelopes.map{try signed($0)}
  for e in events {guard Set(e.keys)==Set(["kind","runID","requestID","resourceID","revision","policyVersion","policyHash","principal","action","route","model","destination","phase","decision","delivery","timestamp"]), e["kind"] as? String == "event",e["resourceID"] as? String == id,e["revision"] as? Int == rev,e["policyVersion"] as? Int == 1,e["policyHash"] as? String == hash,e["principal"] as? String == "native-selected-user",e["action"] as? String == "model_send" else{throw HandoffError.uncertain}}
  guard events[0]["route"] as? String == "cloud",events[0]["decision"] as? String == "deny",events[0]["delivery"] as? String == "not-started",events[0]["phase"] as? String == "result" else{throw HandoffError.uncertain}
  for i in [1,2] {guard events[i]["route"] as? String == "local",events[i]["model"] as? String == "apple-system-default",events[i]["destination"] as? String == "apple-system-on-device" else{throw HandoffError.uncertain}}
  guard events[1]["phase"] as? String == "intent",events[2]["phase"] as? String == "result",events[2]["decision"] as? String == "allow",events[2]["delivery"] as? String == "received",events[1]["requestID"] as? String == events[2]["requestID"] as? String,events[0]["requestID"] as? String != events[1]["requestID"] as? String else{throw HandoffError.uncertain}
  let root=merkle(try ([package["plan"]!]+envelopes.map{$0 as Any}).map{try canonical($0)});let policy=merkle([try canonical(UnifiedPolicy.value)])
  let checkpoint=try signed(package["checkpoint"]!)
  guard Set(checkpoint.keys)==Set(["kind","runID","count","executionRoot","policyRoot"]),checkpoint["kind"] as? String == "checkpoint",checkpoint["executionRoot"] as? String == root,checkpoint["policyRoot"] as? String == policy,checkpoint["count"] as? Int == 4 else{throw HandoffError.uncertain}
  print(String(data:try canonical(["status":"verified","runID":a[3],"resourceID":id,"revision":rev,"policyVersion":1,"policyRoot":policy,"executionRoot":root]),encoding:.utf8)!)
 }
}

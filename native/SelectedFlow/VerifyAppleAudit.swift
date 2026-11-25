import Foundation
import CryptoKit
@main enum VerifyAppleAudit {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let key=try Curve25519.Signing.PublicKey(rawRepresentation:Data(contentsOf:root.appendingPathComponent("public-key.raw")))
  let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
  let expected:Set<String>=["requestID","resourceID","revision","policyVersion","route","model","destination","phase","decision","delivery","timestamp"]
  var events=[[String:Any]]()
  for file in files where file.pathExtension == "json" && file.lastPathComponent != "network-observation.json" {
   let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:String]
   guard Set(envelope.keys)==["metadata","signature"],let data=Data(base64Encoded:envelope["metadata"]!),let sig=Data(base64Encoded:envelope["signature"]!),key.isValidSignature(sig,for:data) else {fatalError("Invalid signature")}
   let event=try JSONSerialization.jsonObject(with:data) as! [String:Any]
   guard Set(event.keys)==expected,UUID(uuidString:event["requestID"] as! String) != nil,UUID(uuidString:event["resourceID"] as! String) != nil else{fatalError("Unexpected metadata")}
   let raw=String(decoding:data,as:UTF8.self)
   for forbidden in ["/Users/","SYNTHETIC VAPE NOTE","blue notebooks","api_key","Bearer ","bookmark","prompt","response"] {guard !raw.contains(forbidden) else{fatalError("Sensitive metadata")}}
   events.append(event)
  }
  let denied=events.filter{$0["route"] as? String == "cloud" && $0["decision"] as? String == "deny" && $0["delivery"] as? String == "not-started"}
  let success=events.filter{$0["route"] as? String == "local" && $0["phase"] as? String == "result" && $0["decision"] as? String == "allow" && $0["model"] as? String == "apple-system-default"}
  guard denied.count>=1,success.count==1,Set(events.compactMap{$0["resourceID"] as? String}).count==1 else {fatalError("Same selected resource outcomes missing")}
  let request=success[0]["requestID"] as! String
  guard events.filter({$0["requestID"] as? String == request && $0["phase"] as? String == "intent"}).count==1 else{fatalError("Intent missing")}
  let network=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("network-observation.json"))) as! [String:Any]
  guard network["ownedLoopbackConnectDenied"] as? Bool == true else{fatalError("App socket denial unverified")}
  print("PASS Apple app audit: \(events.count) Ed25519 records; same resource Cloud pre-call denial + one actual local result; metadata allowlist; app TCP denial observed; Apple services isolation NOT verified")
 }
}

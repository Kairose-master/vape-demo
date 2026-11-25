import Foundation
import CryptoKit

enum SelectedEvidence {
 static func bytes(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
 static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
 static func envelope(_ metadata:[String:Any],key:Curve25519.Signing.PrivateKey)throws->[String:String] {
  let raw=try bytes(metadata);return ["metadata":raw.base64EncodedString(),"signature":try key.signature(for:raw).base64EncodedString()]
 }
 static func verify(_ package:[String:Any],publicKey:String)throws->[String:Any] {
  guard Set(package.keys)==Set(["runID","events"]),let run=package["runID"] as? String,UUID(uuidString:run) != nil,let events=package["events"] as? [[String:String]],events.count==3,let keyData=Data(base64Encoded:publicKey) else{throw CocoaError(.fileReadCorruptFile)}
  let key=try Curve25519.Signing.PublicKey(rawRepresentation:keyData)
  var values=[[String:Any]](),leaves=Data()
  let fields=Set(["schema","runID","resourceID","revision","policyVersion","level","binding","phase","decision","delivery","cloudPolicy","model","externalCalls","reason"])
  for event in events {
   guard Set(event.keys)==Set(["metadata","signature"]),let raw=Data(base64Encoded:event["metadata"]!),let sig=Data(base64Encoded:event["signature"]!),key.isValidSignature(sig,for:raw),let m=try JSONSerialization.jsonObject(with:raw) as? [String:Any],Set(m.keys)==fields,m["schema"] as? Int==1,m["runID"] as? String==run,m["externalCalls"] as? Int==0,m["model"] as? String=="apple-system-default",let rid=m["resourceID"] as? String,UUID(uuidString:rid) != nil,let rev=m["revision"] as? Int,rev>0,let version=m["policyVersion"] as? Int,[1,2].contains(version),let level=m["level"] as? Int,(1...3).contains(level),let binding=m["binding"] as? String,binding.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw CocoaError(.fileReadCorruptFile)}
   values.append(m);leaves.append(contentsOf:SHA256.hash(data:try bytes(event)))
  }
  let first=values[0]
  for m in values {for field in ["resourceID","revision","policyVersion","level","binding","cloudPolicy"] {guard String(describing:m[field]!)==String(describing:first[field]!) else{throw CocoaError(.fileReadCorruptFile)}}}
  guard values.map({$0["phase"] as! String})==["policy","intent","result"],values[0]["decision"] as? String=="allow",values[1]["decision"] as? String=="indeterminate",values[0]["delivery"] as? String=="not-started",values[1]["delivery"] as? String=="not-started",first["cloudPolicy"] as? String == (((first["level"] as! Int)==2 || ((first["policyVersion"] as! Int)==2 && (first["level"] as! Int)==3)) ? "approval-required-no-send":"deny-no-send") else{throw CocoaError(.fileReadCorruptFile)}
  let final=values[2],decision=final["decision"] as? String,delivery=final["delivery"] as? String,reason=final["reason"] as? String ?? ""
  let failures=Set(["appleContextLimit","appleAssetsUnavailable","appleGuardrail","appleUnsupportedGuide","appleUnsupportedLanguage","appleDecoding","appleRateLimited","appleConcurrentRequest","appleRefusal","appleFrameworkError","appleTimeout","appleEmptyResponse","uncertain","runtimeUnverified","needsRegistration"])
  guard (decision=="allow" && delivery=="received" && reason=="completed") || (decision=="indeterminate" && ["unknown","received"].contains(delivery ?? "") && failures.contains(reason)) else{throw CocoaError(.fileReadCorruptFile)}
  let policy:[String:Any]=["policyVersion":first["policyVersion"]!,"resourceID":first["resourceID"]!,"revision":first["revision"]!,"level":first["level"]!,"cloudPolicy":first["cloudPolicy"]!,"local":"allow","binding":first["binding"]!]
  return ["status":"verified","runID":run,"resourceID":first["resourceID"]!,"revision":first["revision"]!,"level":first["level"]!,"policyVersion":first["policyVersion"]!,"policyRoot":hash(try bytes(policy)),"executionRoot":hash(leaves),"cloudPolicy":first["cloudPolicy"]!,"externalCalls":0,"localDecision":decision!,"localDelivery":delivery!,"localReason":reason]
 }
}

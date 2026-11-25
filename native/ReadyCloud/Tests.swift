import Foundation
import CryptoKit
final class FakeCloud:CloudSending {
 var calls=0;var fail=false;var malformed=false
 func send(key:String,body:Data,completion:@escaping(Int?,Data?,Bool)->Void){calls+=1;precondition(key=="synthetic-key-not-a-real-secret")
  let p=try! JSONSerialization.jsonObject(with:body) as! [String:Any];precondition(p["input"] as? String == CloudDemo.text && p["model"] as? String == CloudDemo.model && p["store"] as? Bool == false && p["tools"]==nil)
  if fail{completion(nil,nil,true);return}
  let valid:[String:Any]=["status":"completed","model":CloudDemo.model,"output":[["type":"message","role":"assistant","content":[["type":"output_text","text":"SYNTHETIC TEST RESPONSE"]]]]]
  completion(200,malformed ? Data("bad".utf8):try! JSONSerialization.data(withJSONObject:valid),false)
 }
 func cancel(){}
}
@main enum Tests {
 static func main()throws {
  var checks=0
  func check(_ v:Bool){precondition(v);checks+=1}
  for mode in ["normal","intent-fail","result-fail","transport-fail","malformed","no-approval"] {
   let fake=FakeCloud();fake.fail=mode=="transport-fail";fake.malformed=mode=="malformed";var events=[CloudEvent]();var result:CloudResult?
   let engine=CloudEngine(transport:fake,audit:{event in if (mode=="intent-fail" && event.phase=="intent") || (mode=="result-fail" && event.phase=="result" && event.level==2){throw CocoaError(.fileWriteUnknown)};events.append(event)})
   engine.executeL2(key:"synthetic-key-not-a-real-secret",approved:mode != "no-approval"){result=$0}
   check(result != nil)
   check(fake.calls==((mode=="intent-fail" || mode=="no-approval") ? 0:1))
   if mode=="normal"{check(result!.decision=="allow");check(events.map{$0.level}==[1,2,2]);check(events[0].delivery=="not-started")}
   if mode=="result-fail"{check(result!.decision=="indeterminate" && result!.delivery=="received" && result!.output==nil)}
   if mode != "no-approval"{engine.executeL2(key:"synthetic-key-not-a-real-secret",approved:true){check($0.reason=="one-shot-consumed")}}
   let encoded=String(decoding:try JSONEncoder().encode(events),as:UTF8.self)
   for secret in ["synthetic-key-not-a-real-secret",CloudDemo.text,"SYNTHETIC TEST RESPONSE","/Users/"]{check(!encoded.contains(secret))}
  }
  check(!CloudDemo.permits(level:1,approved:true));check(CloudDemo.permits(level:2,approved:true));check(!CloudDemo.permits(level:3,approved:true))
  check(!CloudDemo.permits(level:2,action:"write",approved:true));check(!CloudDemo.permits(level:2,action:"tool_send",approved:true));check(!CloudDemo.permits(level:2,destination:"other",approved:true));check(!CloudDemo.permits(level:2,model:"other",approved:true))
  check(CloudDemo.endpoint.scheme=="https" && CloudDemo.endpoint.host=="api.openai.com" && CloudDemo.endpoint.path=="/v1/responses")
  let directory=URL(fileURLWithPath:CommandLine.arguments[1]);let audit=try CloudAudit(directory)
  try audit.append(CloudEvent(eventID:UUID(),runID:UUID(),phase:"result",level:1,policyVersion:1,model:CloudDemo.model,destination:"cloud-model",decision:"deny",delivery:"not-started",reason:"L1-cloud-forbidden"))
  let publicKey=try Curve25519.Signing.PublicKey(rawRepresentation:Data(contentsOf:directory.appendingPathComponent("public-key.raw")))
  let file=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).first{$0.pathExtension=="json"}!
  let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:String]
  let metadata=Data(base64Encoded:envelope["metadata"]!)!;check(publicKey.isValidSignature(Data(base64Encoded:envelope["signature"]!)!,for:metadata))
  check(!String(decoding:metadata,as:UTF8.self).contains("synthetic-key-not-a-real-secret"));check(!String(decoding:metadata,as:UTF8.self).contains(CloudDemo.text))
  print("PASS ready-cloud: \(checks) assertions; synthetic key + injected transport only; no API call")
 }
}

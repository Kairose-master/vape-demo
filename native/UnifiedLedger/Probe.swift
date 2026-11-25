import Foundation
import CryptoKit
// Headless synthetic fixture scope only. Does not claim macOS user-picker authorization.
struct ProbePicker:UserFileSelection {let url:URL;func chooseFile()throws->URL?{url}}
struct ProbeAccess:SelectedFileAccess {
 func begin(_ url:URL)->Bool{true};func end(_ url:URL){}
 func makeBookmark(_ url:URL)throws->Data{Data(url.path.utf8)}
 func resolve(_ bookmark:Data)throws->(url:URL,stale:Bool){(URL(fileURLWithPath:String(data:bookmark,encoding:.utf8)!),false)}
}
@main enum UnifiedProbe {
 static var stage="setup",calls=0
 static func main(){do{try run()}catch{
  let code=(error as? HandoffError)?.rawValue ?? (error as? RegistryError)?.rawValue ?? "uncertain"
  let status:[String:Any]=["status":"indeterminate","stage":stage,"reason":code,"localCalls":calls,"retryAutomatically":false]
  let data=try! canonical(status);print(String(data:data,encoding:.utf8)!)
  if CommandLine.arguments.count==2 {try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("diagnostic.json"),options:.withoutOverwriting)}
  exit(1)
 }}
 static func run()throws {
  let base=URL(fileURLWithPath:CommandLine.arguments[1]);let fixture=base.appendingPathComponent("synthetic.txt")
  let text="SYNTHETIC VAPE NOTE: The fictional library ordered three blue notebooks for its reading club. Delivery is on Friday.\n"
  try Data(text.utf8).write(to:fixture,options:.withoutOverwriting)
  let principal=RegistryPrincipal(id:"native-selected-user")
  let registry=try FileClassificationRegistry(storage:PrivateRegistryStore(directory:base.appendingPathComponent("registry")),access:ProbeAccess(),policy:{UnifiedPolicy.snapshot})
  let file=try registry.register(using:ProbePicker(url:fixture),level:.one,principal:principal)!
  let evidence=try UnifiedEvidence(base.appendingPathComponent("exchange"))
  print("identity-ready",terminator:"\n");fflush(stdout)
  for _ in 0..<600 {if evidence.ready{break};Thread.sleep(forTimeInterval:0.1)}
  let expected=digest(Data(text.utf8))
  let handoff=PrivateModelHandoff(registry:registry,principal:principal,configuration:{PrivateModelConfiguration(enabled:true,route:.local,model:"apple-system-default",destinationID:"apple-system-on-device",runtimeReady:{AppleLocalModel.available()},approval:{b in b.resourceID==file.resource_id && b.revision==file.classification_revision && b.policyVersion==1 && b.route == .local && (b.contentDigest==nil || b.contentDigest==expected)},dispatch:{input in stage="apple-generation";calls+=1;return try AppleLocalModel.respond(input,expectedDigest:expected)},syntheticLoopbackOnly:false)},audit:{try evidence.append($0)})
  stage="policy-and-handoff"
  let (cloud,local)=try executeUnifiedDemo(file,evidence,handoff)
  print(String(data:try canonical(["status":"executed","cloud":cloud.decision,"cloudDelivery":cloud.delivery,"local":local.decision,"localDelivery":local.delivery,"localCalls":calls,"responseNonempty":!(local.output ?? "").isEmpty,"scope":"headless real Apple; test file scope adapter; GUI picker not exercised"]),encoding:.utf8)!)
 }
}

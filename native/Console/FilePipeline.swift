import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Darwin

// Restore only the console that owned the initiating interaction. Never activate
// another application after the user has switched away during a modal panel.
final class PipelinePanelFocus {
 private let previous = NSWorkspace.shared.frontmostApplication
 func finish() {
  precondition(Thread.isMainThread)
  guard NSApp.isActive, let previous=previous, !previous.isTerminated,
        previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
        previous.bundleIdentifier?.hasPrefix("org.vape.console.") == true,
        previous.bundleIdentifier?.hasPrefix("org.vape.console.fileregistry.") != true else{return}
  previous.activate(options:[])
 }
}

// Separate process: user-selected read-only files and bookmarks; NO network entitlement.
struct PipelinePicker:UserFileSelection {
 let sample:URL;let synthetic:Bool
 func chooseFile()throws->URL? {
  if synthetic{return sample}
  let panel=NSOpenPanel();panel.title="VAPE · 로컬 TXT 가져오기";panel.message="외부 업로드가 아닙니다. 등급 저장은 모델 전송 승인이 아닙니다.";panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.resolvesAliases=false;panel.allowedContentTypes=[.plainText];panel.directoryURL=sample.deletingLastPathComponent()
  let focus=PipelinePanelFocus()
  defer{panel.orderOut(nil);focus.finish()}
  NSApp.activate(ignoringOtherApps:true)
  return panel.runModal() == .OK ? panel.url:nil
 }
}
struct SyntheticAccess:SelectedFileAccess {
 func begin(_ u:URL)->Bool{true};func end(_ u:URL){}
 func makeBookmark(_ u:URL)throws->Data{Data(u.path.utf8)}
 func resolve(_ d:Data)throws->(url:URL,stale:Bool){(URL(fileURLWithPath:String(decoding:d,as:UTF8.self)),false)}
}
final class Pipeline {
 let root:URL,registry:FileClassificationRegistry,principal=RegistryPrincipal(id:"auditor-a"),consumer=RegistryPrincipal(id:"user-b"),access:SelectedFileAccess,key:Curve25519.Signing.PrivateKey
 var role="user-b"
 fileprivate var runs=[String:([String:Any],RegisteredFile)]()
 private var anchored=Set<String>()
 private var usedWriteApprovals=[String:RegisteredFile]()
 private var writeApprovals=[String:(RegisteredFile,String,String)]()
 private var previews=[String:(RegisteredFile,String,String)]()
 init(synthetic:Bool,isolated:Bool=false)throws {
  let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].standardizedFileURL.resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
  root=support.appendingPathComponent((synthetic || isolated) ? "SyntheticTests-"+UUID().uuidString:"FilePipeline-v1")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  access=synthetic ? SyntheticAccess():MacSelectedFileAccess()
  let keyURL=root.appendingPathComponent("signer.key")
  if FileManager.default.fileExists(atPath:keyURL.path){key=try Curve25519.Signing.PrivateKey(rawRepresentation:Data(contentsOf:keyURL))}
  else {key=Curve25519.Signing.PrivateKey();try key.rawRepresentation.write(to:keyURL,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:keyURL.path)}
  registry=try FileClassificationRegistry(storage:PrivateRegistryStore(directory:root.appendingPathComponent("registry")),access:access,policy:{ClassificationPolicySnapshot(version:2,permits:{i in ["auditor-a","user-b"].contains(i.principal.id) && i.action=="model_send" && (i.modelAlias=="local" || (i.modelAlias=="cloud" && [.two,.three].contains(i.resource.level)))})})
 }
 func write(_ value:Any,_ name:String)throws {let d=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]);try d.write(to:root.appendingPathComponent(name),options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent(name).path)}
 func selected()throws->RegisteredFile {let d=try Data(contentsOf:root.appendingPathComponent("selected.json"));let record=try JSONDecoder().decode(RegisteredFile.self,from:d);return try registry.lookup(resourceID:record.resource_id,principal:principal)}
 func save(_ f:RegisteredFile)throws {try JSONEncoder().encode(f).write(to:root.appendingPathComponent("selected.json"),options:.atomic)}
 func describe(_ f:RegisteredFile)->[String:Any]{["resourceID":f.resource_id.uuidString,"level":f.level.rawValue,"revision":f.classification_revision,"policyVersion":f.policy_version]}
 func event(_ f:RegisteredFile,kind:String,details:[String:Any]=[:])throws->[String:Any] {
  let value:[String:Any]=["kind":kind,"resourceID":f.resource_id.uuidString,"level":f.level.rawValue,"revision":f.classification_revision,"policyVersion":f.policy_version,"eventID":UUID().uuidString,"cloud":kind.hasPrefix("cloud_") ? "intent-only-result-separate":"not-sent","modelCalls":kind.hasPrefix("local_") ? "see-delivery-result":"0"]
  let data=try JSONSerialization.data(withJSONObject:value.merging(details){a,_ in a},options:[.sortedKeys,.withoutEscapingSlashes]);let e:[String:Any]=["metadata":data.base64EncodedString(),"signature":try key.signature(for:data).base64EncodedString()]
  let name="event-"+UUID().uuidString+".json"
  var entries=try checkpoint()
  try write(e,name)
  let raw=try Data(contentsOf:root.appendingPathComponent(name));entries[name]=SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined()
  let manifest=try JSONSerialization.data(withJSONObject:entries,options:.sortedKeys)
  try write(["metadata":manifest.base64EncodedString(),"signature":try key.signature(for:manifest).base64EncodedString()],"checkpoint.json")
  return e
 }
 func track(_ name:String)throws {
  var entries=try checkpoint();entries[name]=SelectedEvidence.hash(try Data(contentsOf:root.appendingPathComponent(name)))
  let raw=try SelectedEvidence.bytes(entries)
  try write(["metadata":raw.base64EncodedString(),"signature":try key.signature(for:raw).base64EncodedString()],"checkpoint.json")
 }
 func checkpoint()throws->[String:String] {
  let url=root.appendingPathComponent("checkpoint.json")
  if !FileManager.default.fileExists(atPath:url.path){return [:]}
  guard let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:String],let m=envelope["metadata"],let s=envelope["signature"],let data=Data(base64Encoded:m),let signature=Data(base64Encoded:s),key.publicKey.isValidSignature(signature,for:data),let entries=try JSONSerialization.jsonObject(with:data) as? [String:String] else{throw RegistryError.corruptStore}
  return entries
 }
 func audit(_ f:RegisteredFile)throws->[String:Any] {
  let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{($0.lastPathComponent.hasPrefix("event-") || $0.lastPathComponent.hasPrefix("run-") || $0.lastPathComponent.hasPrefix("receipt-")) && $0.pathExtension=="json"}
  var events=[[String:Any]]();var valid=true
  let entries=try checkpoint()
  if Set(entries.keys) != Set(files.map{$0.lastPathComponent}){valid=false}
  for file in files {
   let raw=try Data(contentsOf:file)
   if entries[file.lastPathComponent] != SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined(){valid=false}
   if !file.lastPathComponent.hasPrefix("event-"){continue}
   guard let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:String],let metadata=envelope["metadata"],let signature=envelope["signature"],let data=Data(base64Encoded:metadata),let sig=Data(base64Encoded:signature),key.publicKey.isValidSignature(sig,for:data),let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {valid=false;continue}
   if value["kind"] as? String=="revision_write_saved" {
    if let id=value["localRevisionID"] as? String,UUID(uuidString:id) != nil,let digest=value["revisionDigest"] as? String,let contents=try? Data(contentsOf:root.appendingPathComponent("LocalRevisions/"+id+".txt")),SelectedEvidence.hash(contents)==digest {} else{valid=false}
   }
   if value["resourceID"] as? String==f.resource_id.uuidString{events.append(value)}
  }
  var executions=[[String:Any]]()
  for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where file.lastPathComponent.hasPrefix("run-") && file.pathExtension=="json" {
   guard let package=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any] else{valid=false;continue}
   do{var proof=try SelectedEvidence.verify(package,publicKey:key.publicKey.rawRepresentation.base64EncodedString())
    if proof["resourceID"] as? String==f.resource_id.uuidString {
     proof["currentRevision"]=(proof["revision"] as? Int)==f.classification_revision
     let receipt=root.appendingPathComponent("receipt-"+(proof["runID"] as! String)+".json")
     if FileManager.default.fileExists(atPath:receipt.path){
      guard let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:receipt)) as? [String:String],let m=envelope["metadata"],let s=envelope["signature"],let raw=Data(base64Encoded:m),let sig=Data(base64Encoded:s),key.publicKey.isValidSignature(sig,for:raw) else{throw RegistryError.corruptStore}
      proof["chainReceipt"]=try JSONSerialization.jsonObject(with:raw)
     }else{proof["chain"]="unanchored"}
     executions.append(proof)
    }
   }catch{valid=false}
  }
  return ["status":valid && !events.isEmpty ? "verified":"indeterminate","executions":executions,"events":events,"scope":"기기 내 Ed25519 서명 · 외부 신뢰기관 아님","chain":executions.isEmpty ? "unanchored":"historical-observations-in-executions"]
 }
 func attached(_ input:[String:Any])throws->[String:Any] {
  guard role=="user-b" else{throw RegistryError.notOwner}
  guard let action=input["action"] as? String else{throw RegistryError.invalidRequest}
  if action=="identity" {return ["publicKey":key.publicKey.rawRepresentation.base64EncodedString()]}
  if action=="receipt" {
   guard let receipt=input["receipt"] as? [String:Any],let run=receipt["runID"] as? String,let stored=runs[run],anchored.contains(run),receipt["status"] as? String=="verified",receipt["independentRead"] as? Bool==true,receipt["nodeStopped"] as? Bool==true,let transaction=receipt["transaction"] as? String,transaction.range(of:"^0x[0-9a-f]{64}$",options:.regularExpression) != nil else{throw RegistryError.invalidRequest}
   let roots=try SelectedEvidence.verify(stored.0,publicKey:key.publicKey.rawRepresentation.base64EncodedString())
   for field in ["runID","resourceID","revision","policyRoot","executionRoot"] {guard let observed=receipt[field],let expected=roots[field],String(describing:observed)==String(describing:expected) else{throw RegistryError.invalidRequest}}
   // Receipt is a local verifier observation, not a signed remote consensus proof.
   try write(SelectedEvidence.envelope(receipt,key:key),"receipt-"+run+".json");try track("receipt-"+run+".json");return ["status":"saved","runID":run]
  }
  if action=="anchor" {
   guard let run=input["runID"] as? String,let stored=runs[run],!anchored.contains(run),try registry.lookup(resourceID:stored.1.resource_id,principal:consumer)==stored.1 else{throw RegistryError.staleRevision}
   _ = try SelectedEvidence.verify(stored.0,publicKey:key.publicKey.rawRepresentation.base64EncodedString());anchored.insert(run);return ["package":stored.0]
  }
  if action=="list" {return ["status":"loaded","files":try registry.registered(principal:consumer).map{describe($0)}]}
  guard let id=input["resourceID"] as? String,let uuid=UUID(uuidString:id),let revision=input["revision"] as? Int,let prompt=input["prompt"] as? String,!prompt.isEmpty,prompt.utf8.count<=8192 else{throw RegistryError.invalidRequest}
  let file=try registry.lookup(resourceID:uuid,principal:consumer);guard file.classification_revision==revision else{throw RegistryError.staleRevision}
  if action=="local" {
   try save(file)
   let run=UUID().uuidString
   let prepared=try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:file.resource_id,policyVersion:file.policy_version,modelAlias:"local"),expectedRevision:revision,principal:consumer)
   var cloud="approval-required-no-send"
   do{_ = try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:file.resource_id,policyVersion:file.policy_version,modelAlias:"cloud"),expectedRevision:revision,principal:consumer);guard [.two,.three].contains(file.level) else{throw RegistryError.invalidRequest}}
   catch RegistryError.denied {cloud="deny-no-send"}
   let binding=SelectedEvidence.hash(Data((run+"\n"+prompt+"\n"+prepared.text).utf8))
   var events=[[String:String]]()
   func record(_ phase:String,_ decision:String,_ delivery:String,_ reason:String?=nil)throws {
    let m:[String:Any]=["schema":1,"runID":run,"resourceID":file.resource_id.uuidString,"revision":revision,"policyVersion":file.policy_version,"level":file.level.rawValue,"binding":binding,"phase":phase,"decision":decision,"delivery":delivery,"cloudPolicy":cloud,"model":"apple-system-default","externalCalls":0,"reason":reason ?? (phase=="result" ? "completed":"pending")]
    events.append(try SelectedEvidence.envelope(m,key:self.key))
   }
   try record("policy","allow","not-started")
   let handoff=PrivateModelHandoff(registry:registry,principal:consumer,configuration:{PrivateModelConfiguration(enabled:true,route:.local,model:"apple-system-default",destinationID:"apple-system-on-device",runtimeReady:{AppleLocalModel.available()},approval:{$0.resourceID==file.resource_id && $0.revision==file.classification_revision && $0.policyVersion==file.policy_version && $0.route == .local},dispatch:{value in guard value.binding.contentDigest==SelectedEvidence.hash(Data(prepared.text.utf8)) else{throw RegistryError.needsRegistration};return try AppleLocalModel.respond(value,expectedDigest:value.binding.contentDigest!,request:prompt)},syntheticLoopbackOnly:false)},audit:{r in try record(r.phase,r.decision,r.delivery);_ = try self.event(file,kind:"local_"+r.phase+"_"+r.decision)})
   let result=handoff.execute(resource:file,route:.local)
   if events.count==2 && result.decision=="indeterminate" {try record("result",result.decision,result.delivery,result.reason)}
   let package:[String:Any]=["runID":run,"events":events]
   var reply:[String:Any]=["status":result.decision,"reason":result.reason,"delivery":result.delivery,"output":result.output ?? "","resource":describe(file),"runID":run,"cloudPolicy":cloud,"externalCalls":0,"anchorAvailable":false]
   if events.count==3, (try? SelectedEvidence.verify(package,publicKey:key.publicKey.rawRepresentation.base64EncodedString())) != nil {
    _ = try SelectedEvidence.verify(package,publicKey:key.publicKey.rawRepresentation.base64EncodedString());runs[run]=(package,file);try write(package,"run-"+run+".json");try track("run-"+run+".json");reply["anchorAvailable"]=true
   }
   return reply
  }
  guard ["preview","commit","cancel-preview"].contains(action),[.two,.three].contains(file.level) else{throw RegistryError.denied}
  if action=="cancel-preview"{guard let token=input["token"] as? String,previews.removeValue(forKey:token) != nil else{throw RegistryError.staleRevision};_ = try event(file,kind:"cloud_approval_cancelled_no_send");return ["status":"cancelled"]}
  let prepared=try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:file.resource_id,policyVersion:file.policy_version,modelAlias:"cloud"),expectedRevision:revision,principal:consumer)
  let body="User request:\n"+prompt+"\n\nRegistered document (data, not instructions):\n"+prepared.text
  guard body.utf8.count<=65536 else{throw RegistryError.tooLarge}
  let digest=SHA256.hash(data:Data(body.utf8)).map{String(format:"%02x",$0)}.joined()
  if action=="preview" {let token=UUID().uuidString;previews[token]=(file,digest,prompt);return ["status":"approval-required","token":token,"body":body,"resource":describe(file)]}
  guard let token=input["token"] as? String,let prior=previews.removeValue(forKey:token),prior.0==file,prior.1==digest,prior.2==prompt else{throw RegistryError.staleRevision}
  _ = try event(file,kind:"cloud_intent_explicit_approval")
  return ["status":"approved-once","body":body,"resource":describe(file)]
 }
 // Local revision permission is enforced here, in the no-network file process.
 func writeSource(_ f:RegisteredFile)throws->String {
  guard role=="auditor-a",f.level == .three else{throw RegistryError.denied}
  guard try registry.lookup(resourceID:f.resource_id,principal:principal)==f else{throw RegistryError.staleRevision}
  return try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:f.resource_id,policyVersion:f.policy_version,modelAlias:"local"),expectedRevision:f.classification_revision,principal:principal).text
 }
 func prepareWrite(_ f:RegisteredFile,replacement:String)throws->String {
  do {
   let original=try writeSource(f)
   guard !replacement.isEmpty,replacement.utf8.count<=65536,replacement != original,replacement.unicodeScalars.allSatisfy({$0.value==9 || $0.value==10 || $0.value==13 || ($0.value>=32 && $0.value != 127)}) else{throw RegistryError.invalidRequest}
   let token=UUID().uuidString;writeApprovals[token]=(f,original,replacement);return token
  }catch{_ = try event(f,kind:"revision_write_blocked");throw error}
 }
 func finishWrite(_ token:String,approved:Bool)throws->[String:Any] {
  guard let (f,original,replacement)=writeApprovals.removeValue(forKey:token) else{if let f=usedWriteApprovals[token]{_ = try event(f,kind:"revision_write_replay_blocked")};throw RegistryError.staleRevision}
  usedWriteApprovals[token]=f
  if !approved{_ = try event(f,kind:"revision_write_cancelled");return ["status":"cancelled","externalCalls":0]}
  do {
   guard try writeSource(f)==original else{throw RegistryError.needsRegistration}
   let revision=UUID().uuidString
   let directory=root.appendingPathComponent("LocalRevisions")
   try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
   let destination=directory.appendingPathComponent(revision+".txt")
   let details:[String:Any]=["localRevisionID":revision,"sourceDigest":SelectedEvidence.hash(Data(original.utf8)),"revisionDigest":SelectedEvidence.hash(Data(replacement.utf8)),"chain":"unanchored","originalPreserved":true]
   _ = try event(f,kind:"revision_write_intent",details:details)
   // Recheck after audit persistence, immediately before creating a new private file.
   guard try writeSource(f)==original else{throw RegistryError.needsRegistration}
   let fd=Darwin.open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
   guard fd>=0 else{throw RegistryError.unavailable}
   do{try Data(replacement.utf8).withUnsafeBytes{bytes in var offset=0;while offset<bytes.count{let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);guard n>0 else{throw RegistryError.unavailable};offset+=n}};guard fsync(fd)==0 else{throw RegistryError.unavailable};Darwin.close(fd)}catch{Darwin.close(fd);throw error}
   _ = try event(f,kind:"revision_write_saved",details:details)
   return ["status":"saved","localRevisionID":revision,"resource":describe(f),"originalPreserved":true,"chain":"unanchored","externalCalls":0,"scope":"private local derived TXT; original registration unchanged"]
  }catch{_ = try event(f,kind:"revision_write_blocked_or_indeterminate");throw error}
 }
 func editRevision()throws->[String:Any] {
  let f=try selected()
  let original:String
  do{original=try writeSource(f)}catch{_ = try event(f,kind:"revision_write_blocked");throw error}
  let focus=PipelinePanelFocus();defer{focus.finish()}
  let edit=NSAlert();defer{edit.window.orderOut(nil)};edit.messageText="L3 새 로컬 리비전 작성";edit.informativeText="대상 등록 ID: \(f.resource_id) · r\(f.classification_revision) · 정책 v\(f.policy_version)\n원본은 변경하지 않습니다. 외부 전송 없음."
  let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:600,height:280));let editor=NSTextView(frame:scroll.bounds);editor.string=original;editor.isRichText=false;editor.isVerticallyResizable=true;editor.autoresizingMask = .width;editor.textContainer?.widthTracksTextView=true;scroll.documentView=editor;scroll.hasVerticalScroller=true;edit.accessoryView=scroll;edit.addButton(withTitle:"변경 비교");edit.addButton(withTitle:"취소");NSApp.activate(ignoringOtherApps:true)
  guard edit.runModal() == .alertFirstButtonReturn else{_ = try event(f,kind:"revision_write_cancelled");return ["status":"cancelled"]}
  let replacement=editor.string,token=try prepareWrite(f,replacement:editor.string)
  let review=NSAlert();defer{review.window.orderOut(nil)};review.messageText="이 변경을 새 로컬 리비전으로 1회 저장 승인";review.informativeText="등록 ID: \(f.resource_id) · L3 · r\(f.classification_revision) · 정책 v\(f.policy_version)\n삭제(-)와 추가(+) 전체를 확인하세요. 원본 보존 · 외부 전송/체인 기록 없음."
  let diff=NSTextView(frame:scroll.bounds);diff.isEditable=false;diff.string="--- 원본\n"+original.components(separatedBy:"\n").map{"- "+$0}.joined(separator:"\n")+"\n+++ 새 리비전\n"+replacement.components(separatedBy:"\n").map{"+ "+$0}.joined(separator:"\n");diff.isVerticallyResizable=true;diff.autoresizingMask = .width;diff.textContainer?.widthTracksTextView=true
  let comparison=NSScrollView(frame:scroll.frame);comparison.hasVerticalScroller=true;comparison.documentView=diff;review.accessoryView=comparison;review.addButton(withTitle:"이 변경 1회 저장 승인");review.addButton(withTitle:"취소")
  return try finishWrite(token,approved:review.runModal() == .alertFirstButtonReturn)
 }
 func run(_ action:String,level:Int?,synthetic:Bool=false)throws->[String:Any] {
  guard role=="auditor-a" else{throw RegistryError.notOwner}
  switch action {
  case "edit-revision": return try editRevision()
  case "select":
   let samples=root.appendingPathComponent("Samples");try FileManager.default.createDirectory(at:samples,withIntermediateDirectories:true)
   let sample=samples.appendingPathComponent("VAPE-Synthetic.txt")
   if !FileManager.default.fileExists(atPath:sample.path){try Data("SYNTHETIC VAPE NOTE: A fictional library ordered three blue notebooks.\n".utf8).write(to:sample,options:.withoutOverwriting)}
   guard let url=try PipelinePicker(sample:sample,synthetic:synthetic).chooseFile() else{return ["status":"cancelled"]}
   guard access.begin(url) else{throw RegistryError.scopeDenied};defer{access.end(url)}
   let bookmark=try access.makeBookmark(url);try bookmark.write(to:root.appendingPathComponent("pending.bookmark"),options:.atomic)
   try write(["pending":true],"pending.json")
   return ["status":"selected","pending":true,"verification":"stale-or-not-run","chain":"unanchored"]
  case "save":
   guard let number=level,let grade=RegisteredLevel(rawValue:number) else{throw RegistryError.invalidRequest}
   let pending=root.appendingPathComponent("pending.json")
   let f:RegisteredFile
   if FileManager.default.fileExists(atPath:pending.path){
    let u=try access.resolve(Data(contentsOf:root.appendingPathComponent("pending.bookmark")));guard !u.stale else{throw RegistryError.staleBookmark}
    struct Chosen:UserFileSelection {let url:URL;func chooseFile()throws->URL?{url}}
    guard let value=try registry.register(using:Chosen(url:u.url),level:grade,principal:principal) else{throw RegistryError.unavailable};f=value
    try FileManager.default.removeItem(at:pending)
   } else {let old=try selected();f=try registry.changeLevel(resourceID:old.resource_id,to:grade,expectedRevision:old.classification_revision,principal:principal)}
   let granted=try registry.grantRead(resourceID:f.resource_id,readers:[consumer.id],expectedRevision:f.classification_revision,principal:principal)
   try save(granted);_ = try event(granted,kind:"grade_saved_and_user_b_granted")
   return ["status":"saved","resource":describe(try selected()),"verification":"stale-or-not-run","chain":"unanchored"]
  case "revoke":
   let old=try selected();let f=try registry.grantRead(resourceID:old.resource_id,readers:[],expectedRevision:old.classification_revision,principal:principal);try save(f);_ = try event(f,kind:"user_b_revoked");return ["status":"revoked","resource":describe(f),"verification":"invalidated","chain":"unanchored"]
  case "lookup":
   guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("pending.json").path) else{throw RegistryError.needsRegistration}
   return ["status":"loaded","resource":describe(try selected()),"chain":"unanchored"]
  case "verify":
   guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("pending.json").path) else{throw RegistryError.needsRegistration}
   let f=try selected()
   // Registry reads the selected file with scope/fingerprint checks; no model is called.
   _ = try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:f.resource_id,policyVersion:f.policy_version,modelAlias:"local"),expectedRevision:f.classification_revision,principal:principal)
   _ = try event(f,kind:"policy_verified_no_send")
   let verifiedAudit=try audit(f)
   return ["status":verifiedAudit["status"] as? String ?? "indeterminate","resource":describe(f),"read":"allowed-text-snapshot","cloudPolicy":[.two,.three].contains(f.level) ? "requires-separate-send-approval":"deny","write":f.level == .three ? "new-local-revision-requires-approval":"deny","modelCalls":0,"audit":verifiedAudit,"chain":"unanchored","anchorAvailable":false]
  case "audit":
   guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("pending.json").path) else{throw RegistryError.needsRegistration}
   let f=try selected();return ["status":"loaded","resource":describe(f),"audit":try audit(f)]
  default:throw RegistryError.invalidRequest
  }
 }
}
@main enum PipelineMain {
 static func main(){
  _=NSApplication.shared;NSApp.setActivationPolicy(.accessory);NSApp.finishLaunching()
  do {
   if CommandLine.arguments.contains("--self-test") {
    let p=try Pipeline(synthetic:true);let initial=try p.attached(["action":"list"]);precondition((initial["files"] as! [[String:Any]]).isEmpty)
    do{_ = try p.run("save",level:1);fatalError("B grade write accepted")}catch{}
    p.role="auditor-a";_ = try p.run("select",level:nil,synthetic:true);_ = try p.run("save",level:1);let first=try p.selected()
    p.role="user-b";let visible=try p.attached(["action":"list"]);precondition((visible["files"] as! [[String:Any]]).count==1)
    do{_ = try p.registry.changeLevel(resourceID:first.resource_id,to:.two,expectedRevision:first.classification_revision,principal:p.consumer);fatalError("B grade change accepted")}catch{}
    do{_ = try p.registry.prepareText(ModelTextRequest(resourceID:first.resource_id,policyVersion:1,modelAlias:"local"),principal:RegistryPrincipal(id:"user-c"));fatalError("C consumed ungranted ID")}catch{}
    do{_ = try p.attached(["action":"preview","resourceID":first.resource_id.uuidString,"revision":first.classification_revision,"prompt":"SYNTHETIC summarize"]);fatalError("L1 cloud accepted")}catch{}
    p.role="auditor-a";_ = try p.run("verify",level:nil);_ = try p.run("save",level:2);let second=try p.selected()
    p.runs["SYNTHETIC-STALE-ANCHOR"]=([:],first)
    p.role="user-b";do{_ = try p.attached(["action":"anchor","runID":"SYNTHETIC-STALE-ANCHOR"]);fatalError("Stale anchor accepted")}catch{}
    do{_ = try p.attached(["action":"preview","resourceID":first.resource_id.uuidString,"revision":first.classification_revision,"prompt":"SYNTHETIC summarize"]);fatalError("Stale grade accepted")}catch{}
    let preview=try p.attached(["action":"preview","resourceID":second.resource_id.uuidString,"revision":second.classification_revision,"prompt":"SYNTHETIC summarize"]);precondition(preview["status"] as? String=="approval-required")
    p.role="auditor-a";_ = try p.run("revoke",level:nil);p.role="user-b"
    do{_ = try p.attached(["action":"commit","resourceID":second.resource_id.uuidString,"revision":second.classification_revision,"prompt":"SYNTHETIC summarize","token":preview["token"]!]);fatalError("Revoked grant consumed")}catch{}
    let revoked=try p.attached(["action":"list"]);precondition((revoked["files"] as! [[String:Any]]).isEmpty)
    p.role="auditor-a";let f=try p.selected();let audit=try p.audit(f);precondition(audit["status"] as? String=="verified")
    let eventFile=try FileManager.default.contentsOfDirectory(at:p.root,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("event-")}!
    let original=try Data(contentsOf:eventFile);try Data("TAMPERED SYNTHETIC".utf8).write(to:eventFile)
    do{let corrupted=try p.audit(f);precondition(corrupted["status"] as? String=="indeterminate")}catch{}
    try original.write(to:eventFile);try FileManager.default.removeItem(at:eventFile);let missing=try p.audit(f);precondition(missing["status"] as? String=="indeterminate");try original.write(to:eventFile)
    let sample=p.root.appendingPathComponent("Samples/VAPE-Synthetic.txt");try Data("CHANGED SYNTHETIC".utf8).write(to:sample)
    do{_ = try p.run("verify",level:nil);fatalError("Changed file accepted")}catch{}
    let w=try Pipeline(synthetic:true);w.role="auditor-a";_ = try w.run("select",level:nil,synthetic:true);_ = try w.run("save",level:2);let l2=try w.selected()
    do{_ = try w.prepareWrite(l2,replacement:"SYNTHETIC revision");fatalError("L2 write accepted")}catch{}
    _ = try w.run("save",level:3);let l3=try w.selected();let before=try w.writeSource(l3)
    let cancelled=try w.prepareWrite(l3,replacement:"SYNTHETIC cancelled");_ = try w.finishWrite(cancelled,approved:false)
    do{_ = try w.finishWrite(cancelled,approved:true);fatalError("Cancelled approval reused")}catch{}
    let approval=try w.prepareWrite(l3,replacement:"SYNTHETIC saved revision")
    let saved=try w.finishWrite(approval,approved:true);precondition(saved["status"] as? String=="saved")
    let originalAfter=try w.writeSource(l3);precondition(originalAfter==before)
    let revisionURL=w.root.appendingPathComponent("LocalRevisions/"+(saved["localRevisionID"] as! String)+".txt")
    let revisionText=try String(contentsOf:revisionURL,encoding:.utf8);precondition(revisionText=="SYNTHETIC saved revision")
    do{_ = try w.finishWrite(approval,approved:true);fatalError("Approval reused")}catch{}
    let stale=try w.prepareWrite(l3,replacement:"SYNTHETIC stale");_ = try w.run("save",level:2)
    do{_ = try w.finishWrite(stale,approved:true);fatalError("Stale policy accepted")}catch{}
    _ = try w.run("save",level:3);let cloudFile=try w.selected();w.role="user-b"
    var cloudInput:[String:Any]=["action":"commit","resourceID":cloudFile.resource_id.uuidString,"revision":cloudFile.classification_revision,"prompt":"SYNTHETIC approved L3 read"]
    do{_ = try w.attached(cloudInput);fatalError("Unapproved L3 accepted")}catch{}
    cloudInput["action"]="preview";let cp=try w.attached(cloudInput);precondition(cp["status"] as? String=="approval-required")
    cloudInput["token"]=cp["token"];cloudInput["action"]="cancel-preview";_ = try w.attached(cloudInput)
    cloudInput["action"]="commit";do{_ = try w.attached(cloudInput);fatalError("Cancelled L3 token reused")}catch{}
    cloudInput["action"]="preview";let approvedPreview=try w.attached(cloudInput);cloudInput["token"]=approvedPreview["token"];cloudInput["action"]="commit"
    let approvedGrant=try w.attached(cloudInput);precondition(approvedGrant["body"] as? String==approvedPreview["body"] as? String && approvedGrant["status"] as? String=="approved-once")
    precondition((approvedGrant["resource"] as? [String:Any])?["policyVersion"] as? Int==2)
    do{_ = try w.attached(cloudInput);fatalError("L3 approval reused")}catch{}
    cloudInput["action"]="preview";let outdated=try w.attached(cloudInput);w.role="auditor-a";_ = try w.run("save",level:2);w.role="user-b";cloudInput["token"]=outdated["token"];cloudInput["action"]="commit"
    do{_ = try w.attached(cloudInput);fatalError("Old L3 revision approval accepted")}catch{}
    w.role="auditor-a"
    print("PASS policy v2 L3 preview/commit: exact body, no-approval/cancel/replay/stale blocked; write approval independent; external calls 0")
    _ = try w.run("save",level:3);let changed=try w.selected();let changedToken=try w.prepareWrite(changed,replacement:"SYNTHETIC changed source")
    try Data("SYNTHETIC changed original".utf8).write(to:w.root.appendingPathComponent("Samples/VAPE-Synthetic.txt"))
    do{_ = try w.finishWrite(changedToken,approved:true);fatalError("Changed source accepted")}catch{}
    w.role="user-b";do{_ = try w.prepareWrite(changed,replacement:"SYNTHETIC unauthorized");fatalError("B write accepted")}catch{}
    do{_ = try w.attached(["action":"preview","resourceID":changed.resource_id.uuidString,"revision":changed.classification_revision,"prompt":"SYNTHETIC"]);fatalError("Changed L3 source accepted")}catch{}
    w.role="auditor-a";let writeAudit=try w.audit(changed);precondition(writeAudit["status"] as? String=="verified")
    print("PASS local revisions: L2 denied; L3 saved; original preserved; cancel/replay/stale/source-change/B-write denied; changed L3 source denied; signed audit verified; external calls 0")
    print("{\"status\":\"passed\",\"checks\":15,\"modelCalls\":0,\"picker\":\"synthetic-injected\",\"roles\":\"A grants B; B write denied; C denied; stale and revoked rejected\"}");return
   }
   let testing=CommandLine.arguments.contains("--bridge-self-test")
   let p=try Pipeline(synthetic:testing,isolated:CommandLine.arguments.contains("--qa"))
   var ticks=0
   // This probe exists only in an isolated synthetic process, never the GUI bridge.
   let timer=testing ? Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){_ in ticks += 1}:nil
   let bridge=CommandLine.arguments.contains("--bridge")
   DispatchQueue(label:"vape.file-pipeline.stdin").async {
    repeat {
     guard let line=readLine() else{break}
     // Synchronous handoff provides backpressure: no queued/reentrant requests
     // can mutate the registry while runModal is pumping its nested event loop.
     DispatchQueue.main.sync {
      precondition(Thread.isMainThread)
      do {
     let raw=Data(line.utf8);guard raw.count<=131072,let input=try JSONSerialization.jsonObject(with:raw) as? [String:Any],let action=input["action"] as? String else{throw RegistryError.invalidRequest}
     let result:[String:Any]
     if testing && action=="event-loop-probe" {result=["ticks":ticks,"mainThread":Thread.isMainThread]}
     else if action=="role" {guard Set(input.keys)==Set(["action","role"]),let role=input["role"] as? String,["auditor-a","user-b"].contains(role) else{throw RegistryError.invalidRequest};p.role=role;result=["status":"selected","role":role,"scope":"trusted demo role; not external authentication"]}
     else if ["identity","receipt","anchor","list","local","preview","commit","cancel-preview"].contains(action){guard Set(input.keys).isSubset(of:["action","resourceID","revision","prompt","token","runID","receipt"]) else{throw RegistryError.invalidRequest};result=try p.attached(input)}
     else{guard Set(input.keys).isSubset(of:["action","level"]) else{throw RegistryError.invalidRequest};result=try p.run(action,level:input["level"] as? Int,synthetic:testing)}
     print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self));fflush(stdout)
    } catch{let reason=(error as? RegistryError)?.rawValue ?? "indeterminate";print("{\"status\":\"indeterminate\",\"reason\":\""+reason+"\",\"verification\":\"invalidated\",\"chain\":\"unanchored\"}");fflush(stdout)}
     }
    } while bridge
    // EOF and one-shot mode both exit through the running AppKit loop, after
    // the last response was flushed. No stdin wait ever occupies the UI thread.
    DispatchQueue.main.async{NSApp.terminate(nil)}
   }
   NSApp.run()
   timer?.invalidate()
  } catch {let reason=(error as? RegistryError)?.rawValue ?? "indeterminate";print("{\"status\":\"indeterminate\",\"reason\":\""+reason+"\",\"verification\":\"invalidated\",\"chain\":\"unanchored\"}");exit(1)}
 }
}

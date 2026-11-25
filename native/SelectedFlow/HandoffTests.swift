import Foundation
import CryptoKit
import Darwin
final class HMemory:ClassificationStorage {var data:Data?;func load()throws->Data?{data};func save(_ data:Data)throws{self.data=data}}
struct HPicker:UserFileSelection {let url:URL;func chooseFile()throws->URL?{url}}
final class HScope:SelectedFileAccess {
 var reads=0
 func begin(_ url:URL)->Bool{reads+=1;return true};func end(_ url:URL){}
 func makeBookmark(_ url:URL)throws->Data{Data(url.path.utf8)}
 func resolve(_ data:Data)throws->(url:URL,stale:Bool){(URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),false)}
}
// Owned, ephemeral TCP loopback receiver. No HTTP endpoint, path, credential or public caller input.
// Payload is only the newly created synthetic test text. This is not model inference.
final class LoopbackProbe {
 let fd:Int32;let port:UInt16;var count=0;var digest="";let group=DispatchGroup()
 init()throws {
  let listener=socket(AF_INET,SOCK_STREAM,0);fd=listener;precondition(listener>=0)
  var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1");address.sin_port=0
  let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}};precondition(bound==0);precondition(listen(listener,1)==0)
  var length=socklen_t(MemoryLayout<sockaddr_in>.size)
  _=withUnsafeMutablePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(listener,$0,&length)}};port=UInt16(bigEndian:address.sin_port)
  group.enter();DispatchQueue.global().async {
   defer{self.group.leave()};let client=accept(self.fd,nil,nil);guard client>=0 else{return};defer{Darwin.close(client)}
   var received=Data(),bytes=[UInt8](repeating:0,count:4096)
   while true {let n=Darwin.read(client,&bytes,bytes.count);if n<=0{break};received.append(contentsOf:bytes.prefix(n))}
   self.count+=1;self.digest=SHA256.hash(data:received).map{String(format:"%02x",$0)}.joined()
  }
 }
 func send(_ text:String)throws->String {
  let client=socket(AF_INET,SOCK_STREAM,0);defer{Darwin.close(client)}
  var a=sockaddr_in();a.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);a.sin_family=sa_family_t(AF_INET);a.sin_addr.s_addr=inet_addr("127.0.0.1");a.sin_port=port.bigEndian
  let code=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(client,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}};guard code==0 else {throw HandoffError.uncertain}
  let data=Data(text.utf8);try data.withUnsafeBytes {bytes in
   var offset=0;while offset<bytes.count {let n=Darwin.write(client,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);guard n>0 else{throw HandoffError.uncertain};offset+=n}
  };shutdown(client,SHUT_WR);guard group.wait(timeout:.now()+3) == .success else{throw HandoffError.uncertain};return "SYNTHETIC LOOPBACK ACK"
 }
 deinit{Darwin.close(fd)}
}
@main enum HandoffTests {
 static var count=0
 static func check(_ value:Bool){precondition(value);count+=1}
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath();let owner=RegistryPrincipal(id:"trusted-user")
  var index=0;var policyVersion=1
  func setup(_ level:RegisteredLevel)throws->(FileClassificationRegistry,RegisteredFile,HScope,URL){
   index+=1;policyVersion=1;let file=root.appendingPathComponent("synthetic-\(index).txt");try Data("SYNTHETIC PRIVATE HANDOFF\n".utf8).write(to:file)
   let scope=HScope();let r=try FileClassificationRegistry(storage:HMemory(),access:scope,policy:{ClassificationPolicySnapshot(version:policyVersion,permits:{_ in true})}) // Deliberately permissive: executor must enforce L1 cloud itself.
   let resource=try r.register(using:HPicker(url:file),level:level,principal:owner)!;return(r,resource,scope,file)
  }
  func config(_ route:PrivateRoute,destination:String="synthetic-private-test",_ approval:@escaping(HandoffBinding)->Bool={_ in true},_ dispatch:@escaping(PrivateModelInput)throws->String)->PrivateModelConfiguration {
   PrivateModelConfiguration(enabled:true,route:route,model:"synthetic:fixed",destinationID:destination,runtimeReady:{true},approval:approval,dispatch:dispatch,syntheticLoopbackOnly:true)
  }
  // Disabled providers never resolve/read the selected file after registration.
  do{let(r,f,s,_)=try setup(.two);let before=s.reads;let h=PrivateModelHandoff(registry:r,principal:owner,audit:{_ in});check(h.execute(resource:f,route:.local).reason=="disabled");check(s.reads==before)}
  // L1 cloud denied even under permissive organization policy, before any body read.
  do{let(r,f,s,_)=try setup(.one);let before=s.reads;var calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.cloud){_ in calls+=1;return "BAD"}},audit:{_ in});check(h.execute(resource:f,route:.cloud).reason=="routeDenied");check(s.reads==before && calls==0)}
  // Reclassification in the final approval callback invalidates the original approval.
  do{let(r,f,_,_)=try setup(.two);var calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.cloud,{binding in if binding.contentDigest != nil {_ = try! r.changeLevel(resourceID:f.resource_id,to:.one,expectedRevision:1,principal:owner)};return true}){_ in calls+=1;return "BAD"}},audit:{_ in});check(h.execute(resource:f,route:.cloud).decision != "allow");check(calls==0)}
  // Actual TCP synthetic loopback exactly once; duplicate request cannot reuse text.
  for (level,route) in [(RegisteredLevel.one,PrivateRoute.local),(.two,.cloud)] {let(r,f,_,_)=try setup(level);let receiver=try LoopbackProbe();var phases=[String]();let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(route,destination:"owned-loopback:\(receiver.port)"){input in
    guard input.binding.destinationID == "owned-loopback:\(receiver.port)" else{throw HandoffError.modelMismatch};return try receiver.send(input.text)}},audit:{phases.append($0.phase)})
   let id=UUID();let result=h.execute(resource:f,route:route,requestID:id);check(result.decision=="allow" && receiver.count==1);check(phases==["intent","result"])
   check(h.execute(resource:f,route:route,requestID:id).reason=="duplicate" && receiver.count==1)
   check(receiver.digest==SHA256.hash(data:Data("SYNTHETIC PRIVATE HANDOFF\n".utf8)).map{String(format:"%02x",$0)}.joined())}
  // Audit intent failure closes before effect; result failure preserves receipt uncertainty.
  for failPhase in ["intent","result"] {let(r,f,_,_)=try setup(.two);var calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.cloud){_ in calls+=1;return "PRIVATE RESULT"}},audit:{if $0.phase==failPhase{throw HandoffError.uncertain}});let result=h.execute(resource:f,route:.cloud);check(calls==(failPhase=="intent" ? 0:1));check(result.output==nil);if failPhase=="result"{check(result.decision=="indeterminate" && result.delivery=="received")}}
  // File changes in intent logging are caught by the last identity check, before dispatch.
  do{let(r,f,_,file)=try setup(.two);var calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.cloud){_ in calls+=1;return "BAD"}},audit:{if $0.phase=="intent"{try Data("MODIFIED".utf8).write(to:file)}});check(h.execute(resource:f,route:.cloud).decision != "allow");check(calls==0)}
  // Local failure is indeterminate; never retries or switches to a cloud route.
  do{let(r,f,_,_)=try setup(.one);var routes=[PrivateRoute]();let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.local){input in routes.append(input.binding.route);throw HandoffError.uncertain}},audit:{_ in});let result=h.execute(resource:f,route:.local);check(result.decision=="indeterminate");check(routes==[.local] && !result.retryAutomatically)}
  // Policy changes during intent persistence invalidate the prepared body before transport.
  do{let(r,f,_,_)=try setup(.two);var calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.cloud){_ in calls+=1;return "BAD"}},audit:{if $0.phase=="intent"{policyVersion=2}});check(h.execute(resource:f,route:.cloud).reason=="stalePolicy");check(calls==0)}
  // Removing approval after preparation prevents dispatch.
  do{let(r,f,_,_)=try setup(.two);var calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{config(.cloud,{binding in binding.contentDigest == nil}){_ in calls+=1;return "BAD"}},audit:{_ in});check(h.execute(resource:f,route:.cloud).reason=="approvalMissing");check(calls==0)}
  // A changed target cannot inherit the earlier model approval.
  do{let(r,f,_,_)=try setup(.two);var checks=0,calls=0;let h=PrivateModelHandoff(registry:r,principal:owner,configuration:{checks+=1;return config(.cloud,destination:checks==1 ? "owned-loopback:12345":"owned-loopback:12346"){_ in calls+=1;return "BAD"}},audit:{_ in});check(h.execute(resource:f,route:.cloud).reason=="modelMismatch");check(calls==0)}
  print("PASS private handoff: \(count) assertions; actual synthetic TCP loopback once; no inference; scopes injected")
 }
}

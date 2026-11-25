import Foundation
import CryptoKit
import Darwin

enum CloudDemo {
 static let model="gpt-6.1-terra" // Documented demo default, not an inferred organizational approval.
 static let endpoint=URL(string:"https://api.openai.com/v1/responses")!
 static let text="SYNTHETIC VAPE TEST: A fictional library ordered three blue notebooks for its reading club. Delivery is on Friday. Summarize this note in one short Korean sentence."
 static func payload(text:String = CloudDemo.text)throws->Data {try JSONSerialization.data(withJSONObject:["model":model,"input":text,"store":false,"stream":false,"max_output_tokens":256,"reasoning":["effort":"none"]],options:.sortedKeys)}
 static func permits(level:Int,action:String="model_send",destination:String="cloud-model",model:String=CloudDemo.model,approved:Bool)->Bool {
  level==2 && action=="model_send" && destination=="cloud-model" && model==CloudDemo.model && approved
 }
 static func keyFormat(_ value:String)->Bool {value.count>=20 && value.count<512 && value.utf8.allSatisfy{$0>=33 && $0<=126}}
}
struct CloudEvent:Codable {
 let eventID:UUID,runID:UUID,phase:String,level:Int,policyVersion:Int,model:String,destination:String,decision:String,delivery:String,reason:String
}
struct CloudResult {let decision:String,delivery:String,reason:String,output:String?}
protocol CloudSending:AnyObject {func send(key:String,body:Data,completion:@escaping(Int?,Data?,Bool)->Void);func cancel()}
final class HTTPSCloud:NSObject,CloudSending,URLSessionDataDelegate {
 private var session:URLSession?,task:URLSessionDataTask?,completion:((Int?,Data?,Bool)->Void)?
 private var data=Data();private var status:Int?;private var oversized=false
 func send(key:String,body:Data,completion:@escaping(Int?,Data?,Bool)->Void){
  guard task==nil else{completion(nil,nil,true);return};self.completion=completion
  let config=URLSessionConfiguration.ephemeral;config.connectionProxyDictionary=[:];config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.waitsForConnectivity=false;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=45
  let session=URLSession(configuration:config,delegate:self,delegateQueue:nil);self.session=session
  var request=URLRequest(url:CloudDemo.endpoint);request.httpMethod="POST";request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization");request.cachePolicy = .reloadIgnoringLocalCacheData
  task=session.dataTask(with:request);task!.resume()
 }
 func cancel(){task?.cancel();session?.invalidateAndCancel()}
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
  status=(response as? HTTPURLResponse)?.statusCode
  if response.expectedContentLength>1048576 {oversized=true;completionHandler(.cancel)}else{completionHandler(.allow)}
 }
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive chunk:Data){if data.count+chunk.count>1048576{oversized=true;dataTask.cancel()}else{data.append(chunk)}}
 func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){
  let callback=completion;completion=nil;callback?(status,status==200 && !oversized ? data:nil,error != nil || oversized)
  data.removeAll();self.task=nil;session.finishTasksAndInvalidate();self.session=nil
 }
}
final class CloudEngine {
 private let lock=NSRecursiveLock();private var used=false;private let transport:CloudSending
 private let audit:(CloudEvent)throws->Void;private let text:String;let runID=UUID();private(set) var calls=0
 init(transport:CloudSending,audit:@escaping(CloudEvent)throws->Void,text:String = CloudDemo.text){self.transport=transport;self.audit=audit;self.text=text}
 private func record(_ level:Int,_ phase:String,_ decision:String,_ delivery:String,_ reason:String)throws {
  try audit(CloudEvent(eventID:UUID(),runID:runID,phase:phase,level:level,policyVersion:1,model:CloudDemo.model,destination:"cloud-model",decision:decision,delivery:delivery,reason:reason))
 }
 func executeL2(key:String,approved:Bool,completion:@escaping(CloudResult)->Void){
  lock.lock();defer{lock.unlock()}
  guard !used else{completion(CloudResult(decision:"deny",delivery:"not-started",reason:"one-shot-consumed",output:nil));return}
  guard approved,CloudDemo.keyFormat(key),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count<=65536 else{completion(CloudResult(decision:"deny",delivery:"not-started",reason:"approval-or-key-missing",output:nil));return}
  used=true
  do {
   // Same evidence run: hard L1 boundary, no transport call, then explicitly approved fixed L2 fixture.
   guard !CloudDemo.permits(level:1,approved:true),CloudDemo.permits(level:2,approved:approved) else{throw CocoaError(.fileReadUnknown)}
   try record(1,"result","deny","not-started","L1-cloud-forbidden")
   guard calls==0 else{throw CocoaError(.fileReadUnknown)}
   try record(2,"intent","indeterminate","not-started","explicit-single-L2-synthetic-approval")
   let body=try CloudDemo.payload(text:text);calls+=1
   transport.send(key:key,body:body){[self] status,data,failed in
    lock.lock();defer{lock.unlock()}
    var output:String?;var reason="transport-unconfirmed";var decision="indeterminate"
    let delivery=status == nil ? "unknown":"received"
    if !failed,status==200,let data=data,let response=try? JSONSerialization.jsonObject(with:data) as? [String:Any],response["status"] as? String == "completed",response["model"] as? String == CloudDemo.model,let items=response["output"] as? [[String:Any]] {
     let parts=items.filter{$0["type"] as? String == "message" && $0["role"] as? String == "assistant"}.flatMap{$0["content"] as? [[String:Any]] ?? []}
     let refusal=parts.contains{$0["type"] as? String == "refusal"}
     let texts=parts.filter{$0["type"] as? String == "output_text"}.compactMap{$0["text"] as? String}
     if !refusal,!texts.isEmpty {output=texts.joined(separator:"\n");decision="allow";reason="completed"}else{reason="refusal-or-no-text"}
    }else if let status=status {reason="http-status-\(status)"}
    do{try record(2,"result",decision,delivery,reason)}catch{output=nil;decision="indeterminate";reason="result-audit-failed"}
    completion(CloudResult(decision:decision,delivery:delivery,reason:reason,output:output))
   }
  }catch{completion(CloudResult(decision:"indeterminate",delivery:"not-started",reason:"intent-or-preflight-failed",output:nil))}
 }
 func cancel(){lock.lock();defer{lock.unlock()};transport.cancel()}
}
final class CloudAudit {
 private let directory:URL,key=Curve25519.Signing.PrivateKey()
 init(_ directory:URL)throws{self.directory=directory;try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try persist(key.publicKey.rawRepresentation,"public-key.raw")}
 private func persist(_ data:Data,_ name:String)throws {
  let fd=Darwin.open(directory.appendingPathComponent(name).path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw CocoaError(.fileWriteUnknown)};defer{Darwin.close(fd)}
  try data.withUnsafeBytes{bytes in var offset=0;while offset<bytes.count{let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);guard n>0 else{throw CocoaError(.fileWriteUnknown)};offset+=n}};guard fsync(fd)==0 else{throw CocoaError(.fileWriteUnknown)}
  let parent=Darwin.open(directory.path,O_RDONLY|O_DIRECTORY);guard parent>=0 else{throw CocoaError(.fileWriteUnknown)};defer{Darwin.close(parent)};guard fsync(parent)==0 else{throw CocoaError(.fileWriteUnknown)}
 }
 func append(_ event:CloudEvent)throws{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(event);let signature=try key.signature(for:data);let envelope=["metadata":data.base64EncodedString(),"signature":signature.base64EncodedString()];try persist(JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys),event.eventID.uuidString+".json")}
}

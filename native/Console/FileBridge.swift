import Foundation
// Anonymous pipes connect native processes only. Python never reads or logs this stream.
final class FileBridge {
 private let reader:FileHandle,writer:FileHandle,queue=DispatchQueue(label:"vape.private-file-bridge")
 init()throws {
  let a=CommandLine.arguments
  guard let r=a.firstIndex(of:"--file-read-fd"),let w=a.firstIndex(of:"--file-write-fd"),r+1<a.count,w+1<a.count,let read=Int32(a[r+1]),let write=Int32(a[w+1]) else{throw CocoaError(.fileReadUnknown)}
  reader=FileHandle(fileDescriptor:read,closeOnDealloc:true);writer=FileHandle(fileDescriptor:write,closeOnDealloc:true)
 }
 func call(_ value:[String:Any],completion:@escaping([String:Any])->Void){queue.async{
  var result:[String:Any]=["status":"indeterminate","reason":"file-bridge-unavailable","verification":"invalidated"]
  do{
   var request=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys);guard request.count<=131072 else{throw CocoaError(.fileReadTooLarge)};request.append(10);try self.writer.write(contentsOf:request)
   var response=Data()
   while response.count<=2097152 {let byte=try self.reader.read(upToCount:1) ?? Data();guard !byte.isEmpty else{throw CocoaError(.fileReadUnknown)};if byte[0]==10{break};response.append(byte)}
   guard response.count<=2097152,let object=try JSONSerialization.jsonObject(with:response) as? [String:Any] else{throw CocoaError(.fileReadCorruptFile)};result=object
  }catch{}
  DispatchQueue.main.async{completion(result)}
 }}
}

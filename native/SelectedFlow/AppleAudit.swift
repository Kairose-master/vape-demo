import Foundation
import CryptoKit
import Darwin

// Private app-container audit: metadata only, Ed25519, immutable separate files.
// This is local signer evidence, not a chain anchor or external identity attestation.
final class AppleAudit {
 let directory:URL;private let key=Curve25519.Signing.PrivateKey();private let lock=NSLock()
 private(set) var records=0
 init(_ directory:URL)throws {
  self.directory=directory;try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
  try write(key.publicKey.rawRepresentation,to:directory.appendingPathComponent("public-key.raw"))
 }
 private func write(_ data:Data,to url:URL)throws {
  let fd=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw HandoffError.intentFailed};defer{Darwin.close(fd)}
  try data.withUnsafeBytes{bytes in var offset=0;while offset<bytes.count {let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);guard n>0 else{throw HandoffError.intentFailed};offset+=n}}
  guard fsync(fd)==0 else{throw HandoffError.intentFailed}
  let parent=Darwin.open(directory.path,O_RDONLY|O_DIRECTORY);guard parent>=0 else{throw HandoffError.intentFailed};defer{Darwin.close(parent)};guard fsync(parent)==0 else{throw HandoffError.intentFailed}
 }
 func append(_ r:HandoffAuditRecord)throws {
  lock.lock();defer{lock.unlock()}
  let event:[String:Any]=["requestID":r.requestID.uuidString,"resourceID":r.resourceID.uuidString,"revision":r.revision,"policyVersion":r.policyVersion,"route":r.route.rawValue,"model":r.model,"destination":r.destinationID,"phase":r.phase,"decision":r.decision,"delivery":r.delivery,"timestamp":ISO8601DateFormatter().string(from:Date())]
  let data=try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys,.withoutEscapingSlashes])
  let signature=try key.signature(for:data)
  let envelope:[String:Any]=["metadata":data.base64EncodedString(),"signature":signature.base64EncodedString()]
  try write(try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys),to:directory.appendingPathComponent(UUID().uuidString+".json"));records+=1
 }
 func networkProbe(port:Int)throws->Bool {
  let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else{return errno==EPERM};defer{Darwin.close(fd)}
  var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1");address.sin_port=UInt16(port).bigEndian
  let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}};let error=errno
  let denied=result == -1 && (error==EPERM || error==EACCES)
  let data=try JSONSerialization.data(withJSONObject:["ownedLoopbackConnectDenied":denied,"errno":Int(error),"scope":"this app process only; Apple system services not measured"],options:.sortedKeys)
  try write(data,to:directory.appendingPathComponent("network-observation.json"));return denied
 }
}
struct PinnedSyntheticPicker:UserFileSelection {
 let expected:URL
 func chooseFile()throws->URL? {
  guard let selected=try MacUserFileSelection().chooseFile() else{return nil}
  guard selected.standardizedFileURL.resolvingSymlinksInPath().path == expected.standardizedFileURL.resolvingSymlinksInPath().path else {throw RegistryError.denied}
  return selected
 }
}

// Fresh synthetic read/blocked export only. Not sandboxed; no OS-denial claim.
import Foundation
import Darwin
@main enum AuditDemoCLI {
 static func main() throws {
  guard CommandLine.arguments.count == 6 else {exit(64)}
  let folder=URL(fileURLWithPath:CommandLine.arguments[1]), runID=CommandLine.arguments[2]
  let policy=try JSONDecoder().decode(Policy.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
  let port=Int(CommandLine.arguments[4])!, requestID=CommandLine.arguments[5]
  try policy.validate()
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
  let data=Data("SYNTHETIC AUDIT DEMO L2\n".utf8)
  try exclusiveDurableWrite(data,to:folder.appendingPathComponent("L2.txt"))
  let resource=Resource(id:"L2",level:"L2",fileName:"L2.txt",initialSHA256:sha256(data))
  let audit=try NativeSignedAudit(directory:folder.appendingPathComponent("SignedEvidence"),runID:runID)
  print(String(decoding:try canonical(["status":"KEY_READY","runID":runID,"keyID":audit.keyID,"producerPID":String(getpid()),"policyHash":sha256(try canonical(policy))]),as:UTF8.self));fflush(stdout)
  guard readLine() == "PINNED" else {exit(2)}
  let gate=try FileGate(folder:folder,fixture:Fixture(folder:folder.path,resources:[resource]),policy:policy)
  let net=NetworkGate(files:gate,audit:audit,port:port)
  let result=net.send(resourceID:"L2",context:BrokerContext(role:"operator",workflow:"approved-cloud-read"),destination:"unregistered-external",requestID:requestID)
  guard result.decision == "deny",net.attempts == 0,gate.writeAttempts == 0,
        try Data(contentsOf:folder.appendingPathComponent("L2.txt")) == data else {exit(2)}
  _ = try audit.exportRun()
  print("{\"status\":\"EXECUTED\"}")
 }
}

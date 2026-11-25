import Foundation
import Darwin
// Test-only selected-file access double. Does not grant or emulate macOS approval.
struct ProbePicker:UserFileSelection {let url:URL;func chooseFile() throws -> URL?{url}}
struct ProbeScope:SelectedFileAccess {
 func begin(_ url:URL)->Bool{true};func end(_ url:URL){}
 func makeBookmark(_ url:URL) throws -> Data{Data(url.path.utf8)}
 func resolve(_ bookmark:Data) throws -> (url:URL,stale:Bool){(URL(fileURLWithPath:String(decoding:bookmark,as:UTF8.self)),false)}
}
@main enum IntegrationProbe {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
  let config=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
  let file=root.appendingPathComponent("Synthetic.txt");try Data("PRIVATE-SYNTHETIC-INTEGRATION-SENTINEL\n".utf8).write(to:file)
  let principal=RegistryPrincipal(id:"native-selected-user")
  let registry=try FileClassificationRegistry(storage:PrivateRegistryStore(directory:root.appendingPathComponent("registry")),access:ProbeScope(),policy:{ClassificationPolicySnapshot(version:1,permits:{$0.action == "model_send" && ($0.modelAlias == "local" || ($0.modelAlias == "cloud" && $0.resource.level != .one))})})
  func sync(_ r:RegisteredFile,_ active:Bool=true) throws {_ = try MetadataBridge.post(config,"/native/register",["resource_id":r.resource_id.uuidString,"level":r.level.rawValue,"classification_revision":r.classification_revision,"policy_version":r.policy_version,"active":active])}
  func request(_ r:RegisteredFile,_ route:String) throws -> [String:Any] {try MetadataBridge.post(config,"/native/preflight",["resource_id":r.resource_id.uuidString,"classification_revision":r.classification_revision,"policy_version":r.policy_version,"route":route,"action":"model_send"])}
  func check(_ value:Bool){precondition(value)}
  let first=try registry.register(using:ProbePicker(url:file),level:.one,principal:principal)!;try sync(first)
  check(try request(first,"cloud")["reason"] as? String == "L1_cloud_forbidden")
  check(try request(first,"local")["reason"] as? String == "local_disabled")
  let second=try registry.changeLevel(resourceID:first.resource_id,to:.two,expectedRevision:1,principal:principal);try sync(second)
  check(try request(first,"local")["reason"] as? String == "stale_classification_or_policy")
  check(try request(second,"cloud")["reason"] as? String == "cloud_disabled")
  let prepared=try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:second.resource_id,policyVersion:1,modelAlias:"local"),expectedRevision:2,principal:principal)
  precondition(!prepared.text.isEmpty)
  try Data("MODIFIED SYNTHETIC\n".utf8).write(to:file)
  do {_ = try registry.prepareTextRevisionBound(ModelTextRequest(resourceID:second.resource_id,policyVersion:1,modelAlias:"local"),expectedRevision:2,principal:principal);fatalError("Changed file accepted")}
  catch {precondition(error as? RegistryError == .changedFile)}
  try sync(second,false)
  check(try request(second,"local")["reason"] as? String == "unregistered_or_inactive")
  print("PASS native-registry → shared UI metadata bridge → real loopback coordinator; 7 checks; no plaintext sent; scopes injected; no inference")
 }
}

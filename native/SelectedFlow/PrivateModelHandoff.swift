import Foundation
import CryptoKit

// All types here stay within the native process. None is Codable or accepted over HTTP.
enum PrivateRoute:String {case local, cloud}
enum HandoffError:String,Error {case disabled, routeDenied, modelMismatch, approvalMissing, runtimeUnverified, duplicate, intentFailed, uncertain}
struct HandoffBinding:Equatable {
 let resourceID:UUID, revision:Int, policyVersion:Int
 let level:RegisteredLevel, route:PrivateRoute, model:String, destinationID:String
 let contentDigest:String? // Private approval binding; never used as a bearer capability.
}
struct PrivateModelInput {let text:String;let binding:HandoffBinding}
struct PrivateModelResult {let decision:String;let reason:String;let delivery:String;let output:String?;let retryAutomatically=false}
struct HandoffAuditRecord {
 let requestID:UUID,resourceID:UUID,revision:Int,policyVersion:Int,route:PrivateRoute,model:String,destinationID:String
 let phase:String,decision:String,delivery:String
 // No plaintext, model output, paths, bookmark, credentials or external URL.
}
struct PrivateModelConfiguration {
 let enabled:Bool,route:PrivateRoute,model:String,destinationID:String
 let runtimeReady:()->Bool
 let approval:(HandoffBinding)->Bool
 let dispatch:(PrivateModelInput)throws->String
 // External/cloud transport remains disabled. The exact Apple on-device route is additionally admitted.
 let syntheticLoopbackOnly:Bool
 var permittedTransport:Bool {syntheticLoopbackOnly || (route == .local && model == "apple-system-default" && destinationID == "apple-system-on-device")}
}
final class PrivateModelHandoff {
 private let registry:FileClassificationRegistry,principal:RegistryPrincipal
 private let configuration:()->PrivateModelConfiguration?
 private let audit:(HandoffAuditRecord)throws->Void
 private let lock=NSRecursiveLock();private var used=Set<UUID>()
 init(registry:FileClassificationRegistry,principal:RegistryPrincipal,
      configuration:@escaping()->PrivateModelConfiguration? = {nil},audit:@escaping(HandoffAuditRecord)throws->Void) {
  self.registry=registry;self.principal=principal;self.configuration=configuration;self.audit=audit
 }
 func execute(resource:RegisteredFile,route:PrivateRoute,requestID:UUID=UUID())->PrivateModelResult {
  lock.lock();defer{lock.unlock()}
  guard used.insert(requestID).inserted else{return PrivateModelResult(decision:"deny",reason:"duplicate",delivery:"not-started",output:nil)}
  var dispatched=false,received=false,output:String?,intent=false,approved:PrivateModelConfiguration?
  func record(_ phase:String,_ decision:String,_ delivery:String) throws {
   try audit(HandoffAuditRecord(requestID:requestID,resourceID:resource.resource_id,revision:resource.classification_revision,
      policyVersion:resource.policy_version,route:route,model:approved?.model ?? "disabled",destinationID:approved?.destinationID ?? "disabled",phase:phase,decision:decision,delivery:delivery))
  }
  do {
   try registry.consumePreparedText(ModelTextRequest(resourceID:resource.resource_id,policyVersion:resource.policy_version,modelAlias:route.rawValue),expectedRevision:resource.classification_revision,principal:principal,authorize:{current,digest in
    // Hard L1 cloud boundary is independent of configurable classification policy.
    guard !(current.level == .one && route == .cloud) else {throw HandoffError.routeDenied}
    guard let config=self.configuration(),config.enabled,config.permittedTransport else {throw HandoffError.disabled}
    guard config.route == route,config.model.range(of:"^[a-zA-Z0-9._:-]{1,80}$",options:.regularExpression) != nil else {throw HandoffError.modelMismatch}
    guard (config.route == .local && config.model == "apple-system-default" && config.destinationID == "apple-system-on-device") || config.destinationID == "synthetic-private-test" || config.destinationID.range(of:"^owned-loopback:[0-9]{2,5}$",options:.regularExpression) != nil else {throw HandoffError.modelMismatch}
    if let first=approved {guard config.route == first.route,config.model == first.model,config.destinationID == first.destinationID else {throw HandoffError.modelMismatch}}
    guard config.runtimeReady() else {throw HandoffError.runtimeUnverified}
    let binding=HandoffBinding(resourceID:current.resource_id,revision:current.classification_revision,policyVersion:current.policy_version,
        level:current.level,route:route,model:config.model,destinationID:config.destinationID,contentDigest:digest)
    guard config.approval(binding) else {throw HandoffError.approvalMissing}
    approved=config
   },consume:{text,current,revalidate in
    guard let config=approved else {throw HandoffError.disabled}
    do {try record("intent","indeterminate","not-started");intent=true} catch {throw HandoffError.intentFailed}
    // Audit callbacks cannot silently change the configured model/runtime after authorization.
    guard let final=self.configuration(),final.enabled,final.permittedTransport,final.route == config.route,final.model == config.model,final.destinationID == config.destinationID,final.runtimeReady() else {throw HandoffError.runtimeUnverified}
    let binding=HandoffBinding(resourceID:current.resource_id,revision:current.classification_revision,policyVersion:current.policy_version,level:current.level,route:route,model:config.model,destinationID:config.destinationID,
        contentDigest:SHA256.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined())
    guard final.approval(binding) else {throw HandoffError.approvalMissing}
    let latest=try revalidate()
    guard !(latest.level == .one && route == .cloud) else {throw HandoffError.routeDenied}
    dispatched=true
    output=try final.dispatch(PrivateModelInput(text:text,binding:binding));received=true
    try record("result","allow","received")
   })
   return PrivateModelResult(decision:"allow",reason:approved?.syntheticLoopbackOnly == false ? "apple_local_inference_completed":"synthetic_loopback_completed_not_inference",delivery:"received",output:output)
  } catch {
   let reason=(error as? HandoffError)?.rawValue ?? (error as? RegistryError)?.rawValue ?? "uncertain"
   if !dispatched {try? record("result","deny","not-started")}
   return PrivateModelResult(decision:dispatched || intent ? "indeterminate":"deny",reason:reason,delivery:received ? "received":dispatched ? "unknown":"not-started",output:nil)
  }
 }
}

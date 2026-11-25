import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
@main enum Readiness {
 static func main() throws {
  var status="framework_unsupported"
  #if canImport(FoundationModels)
  if #available(macOS 26.0,*) {
   switch SystemLanguageModel.default.availability {
   case .available: status="ready"
   case .unavailable(let reason):
    switch reason {
    case .deviceNotEligible: status="device_unsupported"
    case .appleIntelligenceNotEnabled: status="disabled"
    case .modelNotReady: status="not_ready"
    @unknown default: status="unavailable_unknown"
    }
   }
  } else {status="os_unsupported"}
  #endif
  let data=try JSONSerialization.data(withJSONObject:["status":status,"modelCalls":0,"fallback":false],options:.sortedKeys)
  print(String(decoding:data,as:UTF8.self))
 }
}

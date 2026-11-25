import Foundation
@main enum SelectedVerifier {
 static func main(){do {
  let raw=FileHandle.standardInput.readDataToEndOfFile();guard raw.count<=65536,let input=try JSONSerialization.jsonObject(with:raw) as? [String:Any],Set(input.keys)==Set(["package","publicKey"]),let package=input["package"] as? [String:Any],let key=input["publicKey"] as? String else{throw CocoaError(.fileReadCorruptFile)}
  print(String(decoding:try SelectedEvidence.bytes(SelectedEvidence.verify(package,publicKey:key)),as:UTF8.self))
 }catch{print("{\"status\":\"indeterminate\"}");exit(1)}}
}

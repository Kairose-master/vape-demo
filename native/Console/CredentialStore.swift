import Foundation
import Security

// Only this native process handles secrets. No shell, IPC, logs, or preferences.
struct CredentialFailure:Error {let status:OSStatus
 var message:String {switch status {case errSecItemNotFound:return "저장된 키 없음";case errSecInteractionNotAllowed:return "Keychain 잠김 또는 사용자 접근 승인 필요";case errSecAuthFailed,errSecUserCanceled:return "Keychain 접근 승인 거부/취소";default:return "Keychain 오류 (\(status))"}}
}
final class CredentialStore {
 let service:String
 init(service:String="org.vape.console.openai-key.v1"){self.service=service}
 private var query:[String:Any]{[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"openai-api-key",kSecAttrSynchronizable as String:false]}
 func read(interactive:Bool=false)throws->String {
  var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
  if !interactive{q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail}
  var item:CFTypeRef?;let code=SecItemCopyMatching(q as CFDictionary,&item)
  guard code==errSecSuccess,let data=item as? Data,let value=String(data:data,encoding:.utf8) else{throw CredentialFailure(status:code)}
  return value
 }
 func save(_ value:String)throws {
  let data=Data(value.utf8)
  let code=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
  if code==errSecItemNotFound {
   var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
   let added=SecItemAdd(q as CFDictionary,nil);guard added==errSecSuccess else{throw CredentialFailure(status:added)}
  }else if code != errSecSuccess{throw CredentialFailure(status:code)}
 }
 func delete()throws{let code=SecItemDelete(query as CFDictionary);guard code==errSecSuccess || code==errSecItemNotFound else{throw CredentialFailure(status:code)}}
}

enum CredentialProbe {
 static func run()->Bool {
  let a=CommandLine.arguments;guard let index=a.firstIndex(of:"--synthetic-keychain-probe") else{return false}
  guard index+2<a.count,let id=UUID(uuidString:a[index+1]) else{exit(2)}
  let store=CredentialStore(service:"org.vape.console.synthetic."+id.uuidString)
  do{switch a[index+2] {
   case "save":try store.save("SYNTHETIC-RESTART-NOT-A-REAL-KEY")
   case "read":guard try store.read()=="SYNTHETIC-RESTART-NOT-A-REAL-KEY" else{exit(3)}
   case "delete":try store.delete()
   default:exit(2)
  };print("PASS synthetic Keychain process "+a[index+2])}
  catch{print((error as? CredentialFailure)?.message ?? "Synthetic Keychain failed");exit(1)}
  return true
 }
}

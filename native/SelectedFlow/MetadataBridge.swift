import Foundation

// Same numeric-loopback metadata transport for the sandbox UI and synthetic integration probe.
enum MetadataBridge {
 static func post(_ config:[String:Any],_ path:String,_ value:[String:Any]) throws -> [String:Any] {
  guard let port=config["port"] as? Int,let token=config["token"] as? String else {throw RegistryError.unavailable}
  var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)\(path)")!);request.httpMethod="POST";request.timeoutInterval=5
  request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:value)
  let done=DispatchSemaphore(value:0);var output:[String:Any]?;var failed=true
  let settings=URLSessionConfiguration.ephemeral
  settings.connectionProxyDictionary=[:]
  let session=URLSession(configuration:settings,delegate:NoRedirect(),delegateQueue:nil)
  session.dataTask(with:request){data,response,error in
   defer{done.signal()}
   if error == nil,(response as? HTTPURLResponse)?.statusCode == 200,let data=data, data.count<4096,let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {output=value;failed=false}
  }.resume()
  guard done.wait(timeout:.now()+6) == .success,!failed,let output=output else {session.invalidateAndCancel();throw RegistryError.unavailable}
  session.finishTasksAndInvalidate();return output
 }
}
final class NoRedirect:NSObject,URLSessionTaskDelegate {
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
}

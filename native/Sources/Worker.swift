import Foundation
import Darwin
final class Worker: NSObject, RestrictedWorkerProtocol {
    func probeNetwork(port: Int, reply: @escaping (String) -> Void) {
        var code:Int32 = 0, connected = false
        do {let fd = try connectLoopback(port:port); connected = true; close(fd)}
        catch GateError.posix(let value) {code = value} catch {code = EINVAL}
        let result:[String:Any] = ["workerPID":getpid(),"workerEUID":geteuid(),"connectErrno":code,
            "connected":connected,"deniedByOS": !connected && (code == EPERM || code == EACCES)]
        reply(String(decoding:try! JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
    func probe(path: String, reply: @escaping (String) -> Void) {
        var result: [String: Any] = ["workerPID": getpid(), "workerEUID": geteuid(),
                                   "networkEntitlement": false, "pathTransport": "plain-string-no-extension"]
        for (name, flags) in [("read", O_RDONLY), ("write", O_WRONLY | O_APPEND)] {
            let fd = Darwin.open(path, flags | O_NOFOLLOW | O_CLOEXEC)
            let code = fd < 0 ? errno : 0
            if fd >= 0 { Darwin.close(fd) } // Never write when unexpectedly permitted.
            result[name + "Errno"] = code
            result[name + "DeniedByOS"] = fd < 0 && (code == EPERM || code == EACCES)
            result[name + "Opened"] = fd >= 0
        }
        let encoded = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        reply(String(decoding: encoded, as: UTF8.self))
    }
}
final class WorkerListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: RestrictedWorkerProtocol.self)
        connection.exportedObject = Worker()
        connection.resume()
        return true
    }
}
@main enum WorkerMain {
    static func main() {
        let delegate = WorkerListener()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}

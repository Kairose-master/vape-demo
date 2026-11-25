import Foundation
@objc protocol RestrictedWorkerProtocol {
    // A path string only. No bookmark, security-scoped URL, file descriptor or content is transferred.
    func probeNetwork(port: Int, reply: @escaping (String) -> Void)
    func probe(path: String, reply: @escaping (String) -> Void)
}

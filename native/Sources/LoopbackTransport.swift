import Foundation
import Darwin

struct NetworkConfig: Codable { let runID: String; let port: Int }
struct LoopbackEndpoint {
    let port: Int
    let path: String
    var identity: String {"http://127.0.0.1:\(port)\(path)"}
    func validate() throws {
        guard (1024...65535).contains(port), ["/ingest","/redirect"].contains(path) else {throw GateError.invalidPolicy}
    }
}
// No DNS, proxy, redirect handling, connection pooling or automatic retry. One literal IPv4 target.
func connectLoopback(port: Int) throws -> Int32 {
    guard (1024...65535).contains(port) else {throw GateError.invalidPolicy}
    let fd = socket(AF_INET,SOCK_STREAM,0)
    guard fd >= 0 else {throw GateError.posix(errno)}
    var timeout = timeval(tv_sec:3,tv_usec:0), one:Int32 = 1
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let status = withUnsafePointer(to:&address) {pointer in
        pointer.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}
    }
    if status != 0 {let code = errno; close(fd); throw GateError.posix(code)}
    return fd
}
func postOnce(endpoint: LoopbackEndpoint, requestID: String, content: Data) throws -> Int {
    try endpoint.validate()
    let fd = try connectLoopback(port:endpoint.port); defer {close(fd)}
    let header = "POST \(endpoint.path) HTTP/1.1\r\nHost: 127.0.0.1:\(endpoint.port)\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nX-VAPE-Request-ID: \(requestID)\r\nContent-Length: \(content.count)\r\n\r\n"
    try writeAll(fd,Data(header.utf8)+content)
    var response = Data(), buffer = [UInt8](repeating:0,count:1024)
    while response.count < 8192 {
        let n = Darwin.read(fd,&buffer,buffer.count)
        if n < 0 {throw GateError.posix(errno)}
        if n == 0 {break}
        response.append(contentsOf:buffer.prefix(n))
    }
    let line = String(decoding:response,as:UTF8.self).components(separatedBy:"\r\n").first ?? ""
    let parts = line.split(separator:" ")
    guard parts.count >= 2, parts[0] == "HTTP/1.1", let status = Int(parts[1]) else {throw GateError.posix(EIO)}
    return status // In particular 3xx is NEVER followed.
}

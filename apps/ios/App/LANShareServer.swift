import Darwin
import Foundation
import Network

final class LANShareServer {
    enum Failure: LocalizedError {
        case noLocalAddress
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .noLocalAddress: return "找不到局域网地址。请连接 Wi-Fi 后重试。"
            case .invalidFile: return "找不到可分享的 IPA 文件。"
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.ipalab.web-download")
    private let file: URL
    private let address: IPv4Address
    private let path = "/" + UUID().uuidString.lowercased()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waitingForHeaders: Set<ObjectIdentifier> = []

    init(file: URL, address: IPv4Address? = LANShareServer.localAddress()) throws {
        guard let address else { throw Failure.noLocalAddress }
        guard file.isFileURL, (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw Failure.invalidFile
        }
        self.file = file
        self.address = address
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(_ result: @escaping (Result<URL, Error>) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port,
                   let url = URL(string: "http://\(self.address):\(port.rawValue)\(self.path)") {
                    result(.success(url))
                }
            case .failed(let error), .waiting(let error):
                result(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 4 else { connection.cancel(); return }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            self.waitingForHeaders.insert(id)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .failed, .cancelled: self.close(connection)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.readRequest(connection)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
                if let self, let connection, self.waitingForHeaders.contains(id) { self.close(connection) }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async {
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            self.waitingForHeaders.removeAll()
        }
    }

    private func close(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connections.removeValue(forKey: ObjectIdentifier(connection))
        waitingForHeaders.remove(ObjectIdentifier(connection))
        connection.cancel()
    }

    private func readRequest(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil else { self.close(connection); return }
            var request = buffer
            request.append(data ?? Data())
            guard request.count <= 8192 else {
                self.respond(connection, status: "431 Request Header Fields Too Large")
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.waitingForHeaders.remove(ObjectIdentifier(connection))
                self.handleRequest(connection, request: request)
            } else if complete {
                self.close(connection)
            } else {
                self.readRequest(connection, buffer: request)
            }
        }
    }

    private func handleRequest(_ connection: NWConnection, request: Data) {
        guard let boundary = request.range(of: Data("\r\n".utf8)),
              let line = String(data: request.prefix(upTo: boundary.lowerBound), encoding: .ascii) else {
            respond(connection, status: "400 Bad Request")
            return
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            respond(connection, status: "400 Bad Request")
            return
        }
        let head = parts[0] == "HEAD"
        guard head || parts[0] == "GET" else {
            respond(connection, status: "405 Method Not Allowed", headers: "Allow: GET, HEAD\r\n")
            return
        }
        switch parts[1] {
        case path:
            let page = """
            <!doctype html><html lang="zh-CN"><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>IPA 解密 下载</title>
            <style>body{font:1rem system-ui;margin:10vh auto;padding:0 1.5rem;max-width:30rem;color:#211c40}a{display:inline-block;padding:.85rem 1.2rem;background:#5042bd;color:white;border-radius:.6rem;text-decoration:none}</style>
            <h1>IPA 解密</h1><p>从 iPhone 下载解密后的 IPA。</p><a href="\(path)/ipa">下载 IPA</a></html>
            """
            respond(connection, status: "200 OK", headers: "Content-Type: text/html; charset=utf-8\r\n",
                    data: Data(page.utf8), head: head)
        case path + "/ipa":
            sendFile(connection, head: head)
        default:
            respond(connection, status: "404 Not Found")
        }
    }

    private func header(_ status: String, length: UInt64, extra: String = "") -> Data {
        Data(("HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\nConnection: close\r\n" +
              "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n" +
              "X-Content-Type-Options: nosniff\r\n\(extra)\r\n").utf8)
    }

    private func respond(_ connection: NWConnection, status: String, headers: String = "",
                         data: Data = Data(), head: Bool = false) {
        var response = header(status, length: UInt64(data.count), extra: headers)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }

    private func sendFile(_ connection: NWConnection, head: Bool) {
        let fileHandle: FileHandle
        let length: UInt64
        do {
            fileHandle = try FileHandle(forReadingFrom: file)
            length = try fileHandle.seekToEnd()
            try fileHandle.seek(toOffset: 0)
        } catch {
            respond(connection, status: "404 Not Found")
            return
        }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: safe) ?? "decrypted.ipa"
        let headers = "Content-Type: application/octet-stream\r\n" +
            "Content-Disposition: attachment; filename=\"decrypted.ipa\"; filename*=UTF-8''\(name)\r\n"
        connection.send(content: header("200 OK", length: length, extra: headers),
                        completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !head else {
                try? fileHandle.close()
                self?.close(connection)
                return
            }
            self.pump(fileHandle, connection: connection, remaining: length)
        })
    }

    private func pump(_ file: FileHandle, connection: NWConnection, remaining: UInt64) {
        guard remaining > 0, connections[ObjectIdentifier(connection)] != nil,
              let chunk = try? file.read(upToCount: Int(min(256 * 1024, remaining))), !chunk.isEmpty else {
            try? file.close()
            close(connection)
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? file.close()
                self?.close(connection)
                return
            }
            self.pump(file, connection: connection, remaining: remaining - UInt64(chunk.count))
        })
    }

    static func localAddress() -> IPv4Address? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }

        var candidate: IPv4Address?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let interface = entry.pointee
            current = interface.ifa_next
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4, octets[0] == 10 ||
                    (octets[0] == 172 && (16...31).contains(octets[1])) ||
                    (octets[0] == 192 && octets[1] == 168) ||
                    (octets[0] == 169 && octets[1] == 254),
                  let address = IPv4Address(host) else { continue }
            if name == "en0" { return address }
            candidate = candidate ?? address
        }
        return candidate
    }
}

import CryptoKit
import Foundation
import Network
import UIKit
import WebKit

// A separate Store identity. No system account access, Mac service or JIT is used.
@MainActor final class NativeStoreLogin: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    struct Materials {
        let accountID: String
        let storefront: String
        let cookies: [String: String]
        let machine: String
    }
    private struct Identity: Codable { let guid: String; let hostUUID: String }
    private let directory: URL
    private let identity: Identity
    private let transport: NativeStoreTransport
    private let proofOperations: ((String, Any) async throws -> Any)?
    private var web: WKWebView?
    private var server: NativeRuntimeServer?
    private var navigation: CheckedContinuation<Void, Error>?
    private var origin: URL?
    private var ready = false
    private var cookies: [String: HTTPCookie] = [:]
    private var stage = "initialize"
    private var running = false
    private var deadline: Task<Void, Never>?
    private static let endpoint = URL(string: "https://auth.itunes.apple.com/auth/v1/native")!
    // Kept as a coherent reference protocol profile, independently of the device's OS.
    static let model = "Mac16,12"
    static let agent = "MacAppStore/3.0 OasisBuild/692.1 Oasis/4.4.0 (Macintosh; OS X 27.2; 26B123) AppleWebKit/2625.2.8.11.9 AMS/1 (dt:1) TSE/0"
    private static let storeHeaders = [
        "User-Agent": "MacAppStore/3.0 com.apple.TestFlight/4.4.0 (Macintosh; OS X 27.2; 26B123) AppleWebKit/2625.2.8.11.9 AMS/1 (dt:1)",
        "X-Apple-Client-Application": "com.apple.TestFlight", "X-Apple-Product-Type": model,
        "Accept-Language": "zh-Hans-SG", "X-Apple-Tz": "28800",
        "Accept": "*/*", "Content-Type": "application/x-apple-plist"
    ]

    init(directory: URL, transport: NativeStoreTransport = NativeStoreTransport(),
         proofOperations: ((String, Any) async throws -> Any)? = nil) throws {
        self.directory = directory
        self.transport = transport
        self.proofOperations = proofOperations
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("identity.json")
        if FileManager.default.fileExists(atPath: file.path) {
            identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: file))
            guard identity.guid.range(of: "^[A-F0-9]{12}$", options: .regularExpression) != nil,
                  UUID(uuidString: identity.hostUUID) != nil else { throw Self.issue("identity") }
        } else {
            identity = Identity(guid: try Vault.randomBytes(length: 6).map { String(format: "%02X", $0) }.joined(),
                                hostUUID: UUID().uuidString)
            try JSONEncoder().encode(identity).write(to: file, options: [.atomic, .completeFileProtection])
        }
        super.init()
    }

    static func ownerDirectory(_ owner: String, base: URL) -> URL {
        let hash = SHA256.hash(data: Data(owner.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("native-store/" + hash, isDirectory: true)
    }

    nonisolated static func issue(_ stage: String, status: Int? = nil, code: String? = nil) -> StoreIssue {
        let limited = status == 429 || status == 423
        let message = limited ? "Apple 暂时限制验证请求，请稍后再试。"
            : stage == "credentials" ? "Apple 未接受本次 Store 登录。如果已经收到验证码，请启用「我已收到验证码」后填写新验证码。"
            : stage == "runtime" || stage == "initialize" ? "本机设备验证运行时未能启动。请保持 App 在前台后重试。"
            : "设备验证登录未完成，请查看下方诊断码。"
        return StoreIssue(message: message,
                          diagnostic: "testflight-native/" + stage + (status.map { " HTTP \($0)" } ?? "") + (code.map { " Apple error \($0)" } ?? ""),
                          requiresAccountAction: false)
    }

    func open() async throws {
        if proofOperations != nil { ready = true; return }
        guard web == nil else { return }
        guard let resources = Bundle.main.url(forResource: "NativeStoreRuntime", withExtension: nil) else {
            throw Self.issue("resources")
        }
        let server = try NativeRuntimeServer(directory: resources)
        self.server = server
        let url = try await server.start()
        origin = url
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "nativeStore")
        let web = WKWebView(frame: CGRect(x: -4, y: -4, width: 2, height: 2), configuration: config)
        web.navigationDelegate = self
        self.web = web
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled else { return }
            self?.close()
        }
        // Keep the web process active while a modal verification sheet is presented.
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window?.addSubview(web)
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            web.load(URLRequest(url: url.appendingPathComponent("index.html")))
        }
        let stateFile = directory.appendingPathComponent("amd.json")
        let saved: Any
        if FileManager.default.fileExists(atPath: stateFile.path) {
            saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile))
        } else { saved = NSNull() }
        _ = try await web.callAsyncJavaScript("window.nativeLogin = await import('./ipalab.mjs'); nativeLogin.initialize(identity, saved); return true;",
            arguments: ["identity": ["guid": identity.guid, "hostUUID": identity.hostUUID], "saved": saved], in: nil, contentWorld: .page)
        ready = true
    }

    func close() {
        deadline?.cancel(); deadline = nil
        ready = false
        let pending = navigation; navigation = nil
        pending?.resume(throwing: CancellationError())
        web?.stopLoading()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "nativeStore", contentWorld: .page)
        web?.navigationDelegate = nil
        web?.removeFromSuperview()
        web = nil
        server?.stop(); server = nil
        transport.close()
    }

    private func invoke(_ operation: String, _ input: Any = NSNull()) async throws -> Any {
        try Task.checkCancellation()
        if let proofOperations { return try await proofOperations(operation, input) }
        guard ready, let web else { throw Self.issue("runtime") }
        do {
            let result = try await web.callAsyncJavaScript("return await nativeLogin.invoke(operation, input);",
                arguments: ["operation": operation, "input": input], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            return result ?? NSNull()
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.issue(stage) } // JavaScript failures may contain private native data.
    }

    func runtimeCheck(sign: Bool = false) async throws -> Bool {
        try await open()
        stage = "runtime"
        let value = try await invoke("headers")
        guard value is NSNull || (value as? [String: String])?["X-Apple-AMD-M"]?.isEmpty == false else { return false }
        if sign {
            stage = "sign"
            let signature = try await invoke("sign", Data("IPA 解密 public runtime check".utf8).base64EncodedString()) as? String
            guard let signature, let bytes = Data(base64Encoded: signature), !bytes.isEmpty else { return false }
        }
        return true
    }

    static func exchange(_ materials: Materials, hardware: Data,
                         transport: NativeStoreTransport = NativeStoreTransport()) async throws -> Data {
        defer { transport.close() }
        guard hardware.count == 20, let dsid = UInt64(materials.accountID) else { throw issue("identity") }
        var vendor = Array(hardware.prefix(16))
        vendor[6] = (vendor[6] & 0x0f) | 0x40
        vendor[8] = (vendor[8] & 0x3f) | 0x80
        let vendorID = UUID(uuid: (vendor[0], vendor[1], vendor[2], vendor[3], vendor[4], vendor[5], vendor[6], vendor[7],
                                   vendor[8], vendor[9], vendor[10], vendor[11], vendor[12], vendor[13], vendor[14], vendor[15])).uuidString
        let body: [String: Any] = ["dsId": NSNumber(value: dsid), "storeFrontIdentifier": materials.storefront,
                                  "storeCookies": materials.cookies, "deviceModel": model,
                                  "deviceName": "IPA 解密", "deviceVendorId": vendorID]
        var request = URLRequest(url: URL(string: "https://testflight.apple.com/v1/session/authenticate")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.allHTTPHeaderFields = ["User-Agent": agent, "Accept": "application/json", "Accept-Language": "en-US",
            "Content-Type": "application/json", "X-Apple-AMD-M": materials.machine,
            "X-Apple-Store-Front": materials.storefront, "X-Apple-Device-Model": model]
        let response = try await transport.send(request)
        let value = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
        let fields = value["data"] as? [String: Any] ?? value
        guard (200..<300).contains(response.status),
              let account = fields["accountId"] as? String, !account.isEmpty,
              let session = fields["sessionId"] as? String, !session.isEmpty else {
            let messages = value["messages"] as? [[String: Any]] ?? []
            let rawCode = value["errorCode"] ?? (value["error"] as? [String: Any])?["code"]
                ?? messages.first(where: { ($0["type"] as? String)?.uppercased() == "ERROR" })?["code"]
            let code = rawCode.map { String(describing: $0) } ?? ""
            let safe = code.range(of: "^-?[0-9]{1,7}$", options: .regularExpression) != nil ? " Apple error " + code : ""
            throw StoreIssue(message: "Store 登录已完成，但 TestFlight 未接受本次设备验证凭据。",
                             diagnostic: "testflight-session/exchange-rejected HTTP \(response.status)" + safe,
                             requiresAccountAction: false)
        }
        // The SDK's catalog/download engine accepts this session format. Exchange
        // stays here so reference headers are not mixed with legacy Mac defaults.
        return try JSONSerialization.data(withJSONObject: ["accountId": account, "sessionId": session,
            "dsid": materials.accountID, "udid": hardware.map { String(format: "%02x", $0) }.joined(),
            "deviceVendorId": vendorID, "deviceName": "IPA 解密", "deviceModel": "iPhone12,1",
            "headers": ["X-Apple-AMD-M": materials.machine, "X-Apple-Store-Front": materials.storefront]])
    }

    func login(email: String, password: String, code: String,
               verification: @escaping () async throws -> String) async throws -> Materials {
        guard !running else { throw Self.issue("busy") }
        guard code.isEmpty || (code.count == 6 && code.utf8.allSatisfy({ (48...57).contains($0) })) else {
            throw Self.issue("verification")
        }
        running = true
        defer { running = false }
        try await open()
        do {
            var currentCode = code
            var provisioned = false
            for _ in 0..<3 {
                try Task.checkCancellation()
                stage = "proof"
                let proof = (try await invoke("headers")) as? [String: String] ?? [:]
                let body = try Self.payload(email: email, password: password, code: currentCode, guid: identity.guid)
                stage = "sign"
                guard let signature = try await invoke("sign", body.base64EncodedString()) as? String, !signature.isEmpty else {
                    throw Self.issue("sign")
                }
                stage = "authenticate"
                var headers = Self.storeHeaders.merging(proof) { _, new in new }
                headers["X-Apple-ActionSignature"] = signature
                let response = try await send(Self.endpoint, headers: headers, body: body)
                try Self.requireOK(response)
                let action = response.header("x-apple-amd-action")
                if !action.isEmpty {
                    guard action == "SP", !provisioned else { throw Self.issue("device-action") }
                    let challenge = response.header("x-apple-amd-data")
                    guard !challenge.isEmpty else { throw Self.issue("challenge-missing") }
                    stage = "provision-start"
                    guard let start = try await invoke("start", challenge) as? [String: Any],
                          let session = start["session"], let cpim = start["cpimBase64"] as? String else {
                        throw Self.issue(stage)
                    }
                    stage = "provision-finish"
                    let finishBody = try PropertyListSerialization.data(fromPropertyList: ["clientData": cpim, "guid": identity.guid], format: .xml, options: 0)
                    let finish = try await send(URL(string: "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish")!, headers: Self.storeHeaders, body: finishBody)
                    try Self.requireOK(finish)
                    let values = try Self.decode(finish.data)
                    guard let settings = values["settingInfo"] as? String, let key = values["transportKey"] as? String else {
                        throw Self.issue("provision-format")
                    }
                    _ = try await invoke("finish", ["session": session, "settingInfoBase64": settings, "transportKeyBase64": key])
                    provisioned = true
                    continue // Sign again with freshly generated Store AMD, on the same identity.
                }
                let values = try Self.decode(response.data)
                if Self.requiresCode(values), currentCode.isEmpty {
                    currentCode = try await verification()
                    guard currentCode.count == 6, currentCode.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Self.issue("verification") }
                    continue
                }
                try Self.validateAccount(values)
                return try Self.materials(values, response: response, cookies: Array(cookies.values), proof: proof)
            }
            throw Self.issue("attempt-limit")
        } catch is CancellationError { throw CancellationError() }
        catch let error as StoreIssue { throw error }
        catch is URLError { throw Self.issue(stage + "-network") }
        catch { throw Self.issue(stage) }
    }

    static func payload(email: String, password: String, code: String, guid: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["createSession": true, "credentialSource": 2,
            "guid": guid, "isSilentAuthentication": false, "password": password + code,
            "rmp": "0", "appleId": email, "passwordSettings": ["free": "always", "paid": "always"]], format: .xml, options: 0)
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw issue("response-format")
        }
        return value
    }
    static func requiresCode(_ values: [String: Any]) -> Bool {
        (values["customerMessage"] as? String)?.contains("MZFinance.BadLogin.Configurator_message") == true
    }
    static func validateAccount(_ values: [String: Any]) throws {
        let failure = values["failureType"].map { String(describing: $0) } ?? ""
        let status = values["status"].map { String(describing: $0) } ?? "0"
        let allowed = values["m-allowed"].map { String(describing: $0).lowercased() }
        guard ["", "0"].contains(failure), status == "0", !["0", "false"].contains(allowed ?? "") else {
            let safeCode = failure.range(of: "^-?[0-9]{1,10}$", options: .regularExpression) == nil ? nil : failure
            throw issue("credentials", code: safeCode)
        }
    }
    static func materials(_ values: [String: Any], response: NativeStoreTransport.Reply,
                          cookies: [HTTPCookie], proof: [String: String], now: Date = Date()) throws -> Materials {
        let account = values["accountInfo"] as? [String: Any] ?? [:]
        var root: [String: String] = [:]
        for cookie in cookies where cookie.domain == ".apple.com" && cookie.path == "/" && !cookie.value.isEmpty {
            guard cookie.expiresDate.map({ $0 > now }) ?? true else { continue }
            root[cookie.name] = cookie.value
        }
        // Current ipatool accepts native success responses without accountInfo.
        // Require a real session token, then resolve the DSID from body or the
        // response's account cookies; a missing username is not an auth failure.
        let identityCookies = root.keys.compactMap { name -> String? in
            guard name.hasPrefix("mz_at_ssl-") else { return nil }
            let value = String(name.dropFirst("mz_at_ssl-".count))
            return UInt64(value).map { $0 > 0 && String($0) == value ? value : nil } ?? nil
        }
        guard let token = values["passwordToken"] as? String, !token.isEmpty else {
            throw responseIssue("account-token-missing", values: values, response: response, root: root)
        }
        let rawID = values["dsPersonId"] ?? values["dsId"] ?? account["dsPersonId"]
        let headerID = response.header("x-dsid")
        let cookieID = root["X-Dsid"] ?? (identityCookies.count == 1 ? identityCookies[0] : "")
        let dsid = rawID.map { String(describing: $0) } ?? (!headerID.isEmpty ? headerID : cookieID)
        guard let number = UInt64(dsid), number > 0, String(number) == dsid else {
            throw responseIssue("account-id-missing", values: values, response: response, root: root)
        }
        guard headerID.isEmpty || headerID == dsid else { throw issue("header-account-mismatch") }
        let storefront = ["x-set-apple-store-front", "x-apple-request-store-front", "x-apple-store-front"]
            .map(response.header).first(where: { !$0.isEmpty }) ?? ""
        guard storefront.range(of: "^[0-9]+-[^\\s]+$", options: .regularExpression) != nil,
              let machine = proof["X-Apple-AMD-M"], !machine.isEmpty else { throw issue("proof-missing") }
        guard root["mz_at_ssl-" + dsid]?.isEmpty == false else { throw issue("cookies-missing") }
        if let cookieID = root["X-Dsid"], cookieID != dsid { throw issue("cookie-account-mismatch") }
        return Materials(accountID: dsid, storefront: storefront, cookies: root, machine: machine)
    }

    private static func responseIssue(_ stage: String, values: [String: Any], response: NativeStoreTransport.Reply,
                                      root: [String: String]) -> StoreIssue {
        // Only a fixed field-presence schema, never values or arbitrary server text.
        let account = values["accountInfo"] as? [String: Any] ?? [:]
        let flags = [
            "accountInfo": values["accountInfo"] != nil,
            "username": account["appleId"] is String,
            "dsid": values["dsPersonId"] != nil || values["dsId"] != nil || account["dsPersonId"] != nil,
            "headerDSID": !response.header("x-dsid").isEmpty,
            "token": (values["passwordToken"] as? String)?.isEmpty == false,
            "authCookie": root.keys.contains { $0.hasPrefix("mz_at_ssl-") },
            "dialog": values["dialog"] != nil,
            "message": values["customerMessage"] != nil
        ]
        let evidence = "response-profile " + flags.keys.sorted().map { "\($0)=\(flags[$0]! ? "present" : "absent")" }.joined(separator: " ")
        let known = ["data", "response", "Response", "result", "account", "accountInfo", "dialog", "status", "failureType",
                     "customerMessage", "message", "dsPersonId", "dsId", "passwordToken", "m-allowed", "success"]
        let schema = known.compactMap { name -> String? in
            guard let value = values[name] else { return nil }
            let type = value is String ? "string" : value is [String: Any] ? "object" : value is [Any] ? "array" : value is NSNumber ? "number" : "other"
            return name + ":" + type
        }.joined(separator: " ")
        let base = issue(stage)
        return StoreIssue(message: base.message, diagnostic: (base.diagnostic ?? "") + "\n" + evidence + "\nresponse-schema " + schema,
                          requiresAccountAction: false)
    }
    private static func requireOK(_ response: NativeStoreTransport.Reply) throws {
        guard response.status == 200 else { throw issue("response", status: response.status) }
    }
    private func send(_ url: URL, headers: [String: String], body: Data) async throws -> NativeStoreTransport.Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.allHTTPHeaderFields = headers
        let valid = cookies.values.filter { cookie in
            (cookie.domain == ".apple.com" || cookie.domain == url.host) && (cookie.expiresDate.map { $0 > Date() } ?? true)
                && url.path.hasPrefix(cookie.path)
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: valid) { request.setValue(value, forHTTPHeaderField: name) }
        let reply = try await transport.send(request)
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: reply.headers, for: url) {
            cookies[cookie.domain + "\n" + cookie.path + "\n" + cookie.name] = cookie
        }
        return reply
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let origin, message.frameInfo.securityOrigin.host == origin.host,
              message.frameInfo.securityOrigin.port == origin.port,
              let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
            replyHandler(nil, "Invalid local request"); return
        }
        if operation == "save" {
            do {
                guard let state = body["state"] as? [String: Any], state["guid"] as? String == identity.guid,
                      (state["hostUUID"] as? String)?.lowercased() == identity.hostUUID.lowercased() else { throw Self.issue("state-identity") }
                let data = try JSONSerialization.data(withJSONObject: state)
                guard data.count <= 4 * 1024 * 1024 else { throw Self.issue("state-size") }
                try data.write(to: directory.appendingPathComponent("amd.json"), options: [.atomic, .completeFileProtection])
                replyHandler(true, nil)
            } catch { replyHandler(nil, "Cannot save local device state") }
            return
        }
        let allowed = ["https://s.mzstatic.com/sap/setupCert.plist": "GET", "https://fpinit.itunes.apple.com/v1/signSapSetup": "POST"]
        guard operation == "network", let text = body["url"] as? String, let method = body["method"] as? String,
              allowed[text] == method, let url = URL(string: text) else { replyHandler(nil, "Endpoint denied"); return }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        if let value = body["data"] as? String {
            guard let data = Data(base64Encoded: value), data.count <= 1024 * 1024 else { replyHandler(nil, "Invalid request"); return }
            request.httpBody = data
        }
        Task {
            do {
                let response = try await transport.send(request)
                replyHandler(["status": response.status, "data": response.data.base64EncodedString()], nil)
            } catch { replyHandler(nil, "SAP network request failed") }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let pending = self.navigation; self.navigation = nil; pending?.resume()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let pending = self.navigation; self.navigation = nil; pending?.resume(throwing: Self.issue("runtime"))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }
}

final class NativeStoreTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let data: Data
        func header(_ name: String) -> String { headers.first { $0.key.lowercased() == name.lowercased() }?.value ?? "" }
    }
    private let handler: ((URLRequest) async throws -> Reply)?
    init(handler: ((URLRequest) async throws -> Reply)? = nil) {
        self.handler = handler
        super.init()
    }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> Reply {
        if let handler { return try await handler(request) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else { throw NativeStoreLogin.issue("response-size") }
        return Reply(status: http.statusCode, headers: http.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) }, data: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func close() { session.invalidateAndCancel() }
}

// Only packaged public runtime files are served, over the device's loopback interface.
final class NativeRuntimeServer: @unchecked Sendable {
    private let directory: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.ipalab.native-runtime")
    private let prefix = "/" + UUID().uuidString + "/"
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startup: CheckedContinuation<URL, Error>?
    init(directory: URL) throws {
        self.directory = directory
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { pending in
            startup = pending
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let pending = self.startup else { return }
                switch state {
                case .ready:
                    self.startup = nil
                    pending.resume(returning: URL(string: "http://localhost:\(self.listener.port!.rawValue)\(self.prefix)")!)
                case .failed(let error): self.startup = nil; pending.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async {
            self.listener.cancel()
            self.startup?.resume(throwing: CancellationError()); self.startup = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 12 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: queue)
        read(connection)
        queue.asyncAfter(deadline: .now() + 30) { self.connections.removeValue(forKey: id)?.cancel() }
    }
    private func read(_ connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var buffer = accumulated; buffer.append(data ?? Data())
            guard error == nil, buffer.count <= 16384 else { connection.cancel(); return }
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() } else { self.read(connection, accumulated: buffer) }; return
            }
            let parts = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix(self.prefix) else { connection.cancel(); return }
            let name = String(parts[1].dropFirst(self.prefix.count)).components(separatedBy: "?")[0]
            let allowed = ["index.html", "ipalab.mjs", "sap.wasm", "wasm_exec.js", "unicorn_x86.js", "crypto-api.mjs", "crypto-worker.js", "amd-generator.mjs", "state-store.mjs"]
            guard allowed.contains(name), let content = try? Data(contentsOf: self.directory.appendingPathComponent(name), options: .mappedIfSafe) else { connection.cancel(); return }
            let type = name.hasSuffix(".wasm") ? "application/wasm" : name.hasSuffix(".html") ? "text/html" : "text/javascript"
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-eval' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                connection.send(content: content, completion: .contentProcessed { _ in
                    self.connections.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel()
                })
            })
        }
    }
}

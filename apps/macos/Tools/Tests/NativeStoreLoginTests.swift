// Standalone Simulator test executable; all Store/TF responses are synthetic.
import Foundation
import Security
#if canImport(AppleAuth)
import AppleAuth
#endif

enum Vault {
    static func randomBytes(length: Int) throws -> Data {
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        return data
    }
}
struct StoreIssue: LocalizedError {
    let message: String
    let diagnostic: String?
    let requiresAccountAction: Bool
    var errorDescription: String? { message }
}

@main struct NativeStoreTests {
    @MainActor static func main() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location) }
        let success: [String: Any] = ["dsPersonId": "12345678", "accountInfo": ["appleId": "fixture@example.invalid"], "passwordToken": "fixture-token", "status": 0]
        let successHeaders = ["X-Set-Apple-Store-Front": "143441-1,29",
                              "Set-Cookie": "mz_at_ssl-12345678=fixture-cookie; Path=/; Domain=.apple.com; Secure"]
        func reply(_ values: [String: Any], headers: [String: String] = [:], status: Int = 200) throws -> NativeStoreTransport.Reply {
            .init(status: status, headers: headers, data: try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0))
        }
        var authCalls = 0, finishes = 0, verifications = 0
        var registered = false
        var order: [String] = []
        var savedGUID: String?
        let transport = NativeStoreTransport { request in
            let values = try NativeStoreLogin.decode(request.httpBody!)
            if request.url!.path.hasSuffix("/finish") {
                finishes += 1; order.append("finish-http")
                precondition(values["guid"] as? String == savedGUID)
                precondition(values["clientData"] as? String == "fixture-cpim")
                return try reply(["settingInfo": "fixture-settings", "transportKey": "fixture-key"])
            }
            precondition(request.url!.path == "/auth/v1/native")
            authCalls += 1; order.append("authenticate")
            let guid = values["guid"] as! String
            if let savedGUID { precondition(savedGUID == guid) } else { savedGUID = guid }
            precondition(values["credentialSource"] as? Int == 2)
            precondition(CFGetTypeID(values["createSession"]! as CFTypeRef) == CFBooleanGetTypeID())
            precondition(request.value(forHTTPHeaderField: "X-Apple-ActionSignature") == "fixture-signature")
            if authCalls == 1 {
                precondition(request.value(forHTTPHeaderField: "X-Apple-AMD-M") == nil)
                return .init(status: 200, headers: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": "fixture-challenge"], data: Data())
            }
            precondition(request.value(forHTTPHeaderField: "X-Apple-AMD-M") == "registered-machine")
            precondition(values["password"] as? String == (authCalls == 2 ? "fixture-password" : "fixture-password123456"))
            if authCalls == 2 { return try reply(["customerMessage": "MZFinance.BadLogin.Configurator_message", "failureType": "-5000"]) }
            return try reply(success, headers: successHeaders)
        }
        let runtime = try NativeStoreLogin(directory: location, transport: transport) { op, input in
            order.append(op)
            switch op {
            case "headers": return registered ? ["X-Apple-AMD-M": "registered-machine", "X-Apple-AMD": "fresh-otp"] : NSNull()
            case "sign":
                precondition(Data(base64Encoded: input as! String) != nil)
                return "fixture-signature"
            case "start":
                precondition(input as? String == "fixture-challenge")
                return ["session": 12, "cpimBase64": "fixture-cpim"] as [String: Any]
            case "finish": registered = true; return ["status": 0]
            default: preconditionFailure("Unexpected proof operation")
            }
        }
        let result = try await runtime.login(email: "fixture@example.invalid", password: "fixture-password", code: "") {
            verifications += 1; return "123456"
        }
        runtime.close()
        precondition(authCalls == 3 && finishes == 1 && verifications == 1)
        precondition(result.machine == "registered-machine" && result.storefront == "143441-1,29")
        precondition(result.cookies["mz_at_ssl-12345678"] == "fixture-cookie")
        precondition(order == ["headers", "sign", "authenticate", "start", "finish-http", "finish", "headers", "sign", "authenticate", "headers", "sign", "authenticate"])
        print("PASS SP registration, same GUID, fresh proof, exact signed payload and verification continuation")

        var limitedCalls = 0
        let limited = try NativeStoreLogin(directory: location, transport: NativeStoreTransport { _ in
            limitedCalls += 1
            return .init(status: 429, headers: [:], data: Data())
        }, proofOperations: { op, _ in op == "sign" ? "fixture-signature" as Any : NSNull() })
        do {
            _ = try await limited.login(email: "fixture@example.invalid", password: "fixture-password", code: "") { preconditionFailure("Must not ask for code") }
            preconditionFailure("Must reject rate limit")
        } catch let issue as StoreIssue { precondition(issue.diagnostic == "testflight-native/response HTTP 429") }
        limited.close()
        precondition(limitedCalls == 1)
        precondition(!NativeStoreLogin.requiresCode(["failureType": "-5000"]))
        print("PASS no automatic retry on 429; ambiguous -5000 does not claim a code was sent")

        var repeatedCalls = 0
        let repeated = try NativeStoreLogin(directory: location, transport: NativeStoreTransport { request in
            if request.url!.path.hasSuffix("/finish") { return try reply(["settingInfo": "x", "transportKey": "y"]) }
            repeatedCalls += 1
            return .init(status: 200, headers: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": "fixture"], data: Data())
        }, proofOperations: { op, _ in
            if op == "start" { return ["session": 1, "cpimBase64": "fixture"] as [String: Any] }
            return op == "sign" ? "fixture-signature" as Any : NSNull()
        })
        do {
            _ = try await repeated.login(email: "fixture@example.invalid", password: "fixture-password", code: "") { "123456" }
            preconditionFailure("Repeated SP must stop")
        } catch let issue as StoreIssue { precondition(issue.diagnostic == "testflight-native/device-action") }
        repeated.close()
        precondition(repeatedCalls == 2)
        print("PASS repeated device challenge stops instead of looping")

        let cookie = HTTPCookie(properties: [.name: "mz_at_ssl-12345678", .value: "fixture", .domain: ".apple.com", .path: "/"])!
        let wrong = HTTPCookie(properties: [.name: "mz_at_ssl-9999", .value: "fixture", .domain: ".apple.com", .path: "/"])!
        let expired = HTTPCookie(properties: [.name: "mz_at_ssl-12345678", .value: "fixture", .domain: ".apple.com", .path: "/", .expires: Date.distantPast])!
        for cookies in [[wrong], [expired]] {
            do {
                _ = try NativeStoreLogin.materials(success, response: reply(success, headers: successHeaders), cookies: cookies, proof: ["X-Apple-AMD-M": "fixture"])
                preconditionFailure("Invalid cookies must fail")
            } catch let issue as StoreIssue { precondition(issue.diagnostic == "testflight-native/cookies-missing") }
        }
        _ = try NativeStoreLogin.materials(success, response: reply(success, headers: successHeaders), cookies: [cookie], proof: ["X-Apple-AMD-M": "fixture"])
        print("PASS other-account and expired cookies cannot reach TestFlight exchange")

        let minimal: [String: Any] = ["passwordToken": "fixture-token", "status": 0]
        let resolved = try NativeStoreLogin.materials(minimal, response: reply(minimal, headers: successHeaders),
                                                     cookies: [cookie], proof: ["X-Apple-AMD-M": "fixture"])
        precondition(resolved.accountID == "12345678")
        var headerOnly = successHeaders
        headerOnly["X-Dsid"] = "12345678"
        _ = try NativeStoreLogin.materials(minimal, response: reply(minimal, headers: headerOnly),
                                           cookies: [cookie], proof: ["X-Apple-AMD-M": "fixture"])
        do {
            _ = try NativeStoreLogin.materials([:], response: reply([:], headers: successHeaders),
                                              cookies: [cookie], proof: ["X-Apple-AMD-M": "fixture"])
            preconditionFailure("Cookie without a session token must not establish login")
        } catch let issue as StoreIssue {
            precondition(issue.diagnostic?.hasPrefix("testflight-native/account-token-missing") == true)
            precondition(!issue.diagnostic!.contains("12345678"))
            precondition(!issue.diagnostic!.contains("fixture-token"))
        }
        print("PASS missing accountInfo and body DSID supported; missing token remains an error with safe schema")

        let hardware = Data(repeating: 7, count: 20)
        var vendorID: String?
        for _ in 0..<2 {
            let data = try await NativeStoreLogin.exchange(result, hardware: hardware, transport: NativeStoreTransport { request in
                precondition(request.url!.host == "testflight.apple.com")
                precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
                precondition(request.value(forHTTPHeaderField: "X-Apple-AMD-M") == result.machine)
                precondition(request.value(forHTTPHeaderField: "X-Apple-TA-Device") == nil)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(body["dsId"] as? UInt64 == 12345678)
                precondition(body["storeFrontIdentifier"] as? String == "143441-1,29")
                precondition(body["storeCookies"] as? [String: String] == result.cookies)
                let vendor = body["deviceVendorId"] as! String
                if let vendorID { precondition(vendor == vendorID) } else { vendorID = vendor }
                return .init(status: 200, headers: [:], data: Data(#"{"data":{"accountId":"fixture-account","sessionId":"fixture-session"}}"#.utf8))
            })
            let session = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(session["dsid"] as? String == result.accountID)
            #if canImport(AppleAuth)
            let client = try await TestFlightClient.deserialize(data, transport: { request in
                precondition(request.url?.path == "/v4/accounts/fixture-account/apps")
                precondition(request.value(forHTTPHeaderField: "X-Session-Id") == "fixture-session")
                return HTTPResponse(status: 200, body: Data(#"{"data":[{"bundleId":"local.fixture.beta"}]}"#.utf8))
            })
            let catalog = try await client.catalog()
            precondition(String(decoding: catalog, as: UTF8.self).contains("local.fixture.beta"))
            let key = Data(repeating: 5, count: 32)
            let encrypted = try await client.serialize(encryptionKey: key)
            precondition(!String(decoding: encrypted, as: UTF8.self).contains("fixture-session"))
            _ = try await TestFlightClient.deserialize(encrypted, encryptionKey: key)
            #endif
        }
        print("PASS exact Store proof and cookies, full storefront, numeric DSID, stable vendor and catalog session format")
        #if canImport(AppleAuth)
        print("PASS real SDK imports new session, signs catalog request and restores encrypted session")
        #endif

        do {
            _ = try await NativeStoreLogin.exchange(result, hardware: hardware, transport: NativeStoreTransport { _ in
                .init(status: 401, headers: [:], data: Data(#"{"messages":[{"type":"ERROR","code":102,"message":"private fixture"}]}"#.utf8))
            })
            preconditionFailure("Exchange rejection must propagate")
        } catch let issue as StoreIssue {
            precondition(issue.diagnostic == "testflight-session/exchange-rejected HTTP 401 Apple error 102")
            precondition(!issue.message.contains("private fixture"))
        }
        print("PASS Apple error 102 preserved without exposing response text")

        #if canImport(AppleAuth)
        let ids = (1...26).map { 2000 + $0 }
        let stored: [String: Any] = ["accountId": "fixture-account", "sessionId": "fixture-session", "dsid": "12345678",
            "udid": String(repeating: "07", count: 20), "deviceModel": "iPhone12,1",
            "headers": ["X-Apple-AMD-M": "fixture-machine", "X-Apple-Store-Front": "143441-1,29"]]
        let catalogClient = try await TestFlightClient.deserialize(JSONSerialization.data(withJSONObject: stored), transport: { request in
            let path = request.url!.path
            let body: [String: Any]
            if path.hasSuffix("/apps") {
                precondition(request.httpMethod == "GET")
                body = ["data": ids.map { ["appId": $0, "name": "Outline"] }]
            } else if path.hasSuffix("/appDetails") {
                precondition(request.httpMethod == "POST")
                let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let apps = input["apps"] as! [[String: Int]]
                precondition((1...25).contains(apps.count))
                body = ["data": apps.map { app -> [String: Any] in
                    let id = app["appId"]!
                    precondition(ids.contains(id))
                    return ["appAdamId": id, "name": "Test App \(id)", "platforms": [
                        ["name": "iOS", "bundleId": "local.fixture.app\(id)",
                         "build": ["id": "build-\(id)", "name": "Build title", "bundleId": "local.fixture.app\(id)"]]
                    ]]
                }]
            } else {
                // Install resolution must inherit the app ID for a platform's bundle.
                precondition(path == "/v3/accounts/fixture-account/apps/2001")
                return HTTPResponse(status: 503, body: Data())
            }
            return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: body))
        })
        let listing = try Beta.catalog(await catalogClient.catalog())
        precondition(listing.count == 26)
        precondition(listing.first(where: { $0.id == "local.fixture.app2001" })?.name == "Test App 2001")
        do {
            _ = try await catalogClient.installMetadata(bundle: "local.fixture.app2001")
            preconditionFailure("Fixture intentionally stops after app resolution")
        } catch { precondition(error.localizedDescription.contains("HTTP 503")) }
        let emptyCatalog = try Beta.catalog(Data(#"{"data":[]}"#.utf8))
        precondition(emptyCatalog.isEmpty)
        print("PASS 26 outline apps resolve through batched appDetails; nested bundles retain app names and install IDs")
        #endif
    }
}

// Runs the shipped local WebKit proof runtime with fresh identity; never logs into Apple.
import AppKit
import Foundation
import Security

struct StoreIssue: LocalizedError {
    let message: String
    let diagnostic: String?
    let requiresAccountAction: Bool
    var errorDescription: String? { message }
}
enum Vault {
    static func randomBytes(length: Int) throws -> Data {
        var value = Data(count: length)
        let status = value.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        return value
    }
}
@main struct PortableRuntimeTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-fresh-runtime-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let live = NativeStoreTransport()
                defer { live.close() }
                let transport = NativeStoreTransport { request in
                    let allowed = ["https://s.mzstatic.com/sap/setupCert.plist": "GET", "https://fpinit.itunes.apple.com/v1/signSapSetup": "POST"]
                    guard let url = request.url?.absoluteString, allowed[url] == request.httpMethod else {
                        throw StoreIssue(message: "Account authentication disabled in this test", diagnostic: "unexpected-endpoint", requiresAccountAction: false)
                    }
                    return try await live.send(request)
                }
                let runtime = try NativeStoreLogin(directory: directory, transport: transport)
                defer { runtime.close() }
                guard try await runtime.runtimeCheck(sign: true) else { throw StoreIssue(message: "Proof check returned false", diagnostic: nil, requiresAccountAction: false) }
                print("PASS portable WebKit runtime: fresh identity, bundled WASM, signature; Apple auth disabled")
                fflush(stdout)
                app.terminate(nil)
            } catch {
                print("FAIL portable WebKit runtime: \((error as? StoreIssue)?.diagnostic ?? "non-protocol-error")")
                fflush(stdout)
                exit(1)
            }
        }
        app.run()
    }
}

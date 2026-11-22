import Foundation

@main struct BetaCatalogFailureTests {
    static func main() {
        precondition(BetaCatalogFailure.session(401).requiresReauthentication)
        precondition(!BetaCatalogFailure.network(-1009).requiresReauthentication)
        let secret = "private-account@example.invalid cookie=secret"
        let expired = BetaCatalogFailure.provider(message: "HTTP 401 " + secret, code: -5).localizedDescription
        precondition(expired.contains("HTTP 401") && expired.contains("重新验证"))
        precondition(!expired.contains(secret) && !expired.contains("cookie="))
        let server = BetaCatalogFailure.provider(message: "HTTP status code: 503 " + secret, code: -8).localizedDescription
        precondition(server.contains("HTTP 503") && !server.contains("重新验证"))
        let unknown = BetaCatalogFailure.provider(message: secret + " 401", code: -3).localizedDescription
        precondition(!unknown.contains(secret) && !unknown.contains("HTTP 401"))
        precondition(BetaCatalogFailure.network(-1009).localizedDescription.contains("network -1009"))
        print("PASS: session, provider and network diagnostics; response bodies excluded")
    }
}

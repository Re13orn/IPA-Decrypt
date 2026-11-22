import Foundation

enum BetaCatalogFailure: LocalizedError {
    case session(Int?)
    case providerCode(Int32, Int?)
    case network(Int)
    case invalidResponse

    static func provider(message: String, code: Int32) -> Self {
        // Only allowlisted status numbers leave the provider response. Never display its body.
        let pattern = #"(?i)\bHTTP(?:\s+status|\s+status\s+code)?[\s:=]+([1-5][0-9]{2})\b"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(message.startIndex..., in: message)
        let status = regex?.firstMatch(in: message, range: range).flatMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: message) else { return nil }
            return Int(message[range])
        }
        if status == 401 || status == 403 { return .session(status) }
        return .providerCode(code, status)
    }

    var requiresReauthentication: Bool {
        if case .session = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .session(let status):
            return "TestFlight 拒绝了当前会话，请在账户设置中重新验证。\n诊断：testflight/catalog HTTP \(status ?? 401)"
        case .providerCode(let code, let status):
            return "TestFlight 请求未完成，请刷新后重试。\n诊断：testflight/catalog provider \(code)" + (status.map { " HTTP \($0)" } ?? "")
        case .network(let code):
            return "无法连接 TestFlight，请检查网络后重试。\n诊断：testflight/catalog network \(code)"
        case .invalidResponse:
            return "TestFlight 返回的列表无法解析，请稍后刷新。\n诊断：testflight/catalog invalid-response"
        }
    }
}

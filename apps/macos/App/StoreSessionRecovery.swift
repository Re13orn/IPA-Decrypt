import Foundation

enum StoreRecoveryFailure: LocalizedError {
    case manualRequired, passwordUnavailable, disabled, accountChanged
    var errorDescription: String? {
        switch self {
        case .manualRequired: return "自动登录未能完成。请在 Apple 账户中手动重新登录后重试。"
        case .passwordUnavailable: return "此 Mac 未保存或暂时无法读取该账户密码。请解锁 Mac 后重试，或手动登录。"
        case .disabled: return "App Store 会话已失效，请手动登录，或开启自动重新登录。"
        case .accountChanged: return "当前账户已切换，已停止原账户操作，请重新发起。"
        }
    }
}

enum StoreAuthenticationRetryPolicy {
    // Only allowlisted preparation/service failures. Never retry credentials,
    // verification, account restrictions, cancellation or HTTP 429.
    static func permits(diagnostic: String?, requiresAccountAction: Bool) -> Bool {
        guard !requiresAccountAction, let diagnostic, !diagnostic.contains(" Apple ") else { return false }
        let preparation = ["login/bag-auth-endpoint", "login/endpoint", "login/store-runtime", "login/store-framework"]
        if preparation.contains(diagnostic) { return true }
        let prefix = "login/request HTTP "
        guard diagnostic.hasPrefix(prefix) else { return false }
        let statuses = diagnostic.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false)
        guard !statuses.isEmpty, statuses.count <= 3 else { return false }
        return statuses.allSatisfy { value in
            guard let status = Int(value.trimmingCharacters(in: .whitespaces)), [204, 404, 500, 502, 503, 504].contains(status) else { return false }
            return true
        }
    }
}

@MainActor final class StoreSessionRecovery {
    private var flights: [String: Task<Void, Error>] = [:]
    private var blocked = Set<String>()
    func isBlocked(_ owner: String) -> Bool { blocked.contains(owner) }
    func reset(_ owner: String) { blocked.remove(owner) }
    func resetFailures() { blocked.removeAll() }

    private func recover(_ owner: String, authenticate: @escaping @MainActor () async throws -> Void,
                         mayRetry: @escaping @MainActor (Error) -> Bool,
                         pause: @escaping @MainActor () async throws -> Void) async throws {
        if let task = flights[owner] { try await task.value; return }
        guard !blocked.contains(owner) else { throw StoreRecoveryFailure.manualRequired }
        let task = Task {
            try Task.checkCancellation()
            do { try await authenticate() }
            catch {
                guard !(error is CancellationError), mayRetry(error) else { throw error }
                try await pause()
                try Task.checkCancellation()
                // At most one fresh authentication cycle after an allowlisted
                // transient failure, in the same coalesced recovery task.
                try await authenticate()
            }
        }
        flights[owner] = task
        defer { flights.removeValue(forKey: owner) }
        do { try await task.value }
        catch {
            if !(error is CancellationError) {
                if let failure = error as? StoreRecoveryFailure {
                    if case .manualRequired = failure { blocked.insert(owner) }
                } else { blocked.insert(owner) }
            }
            throw error
        }
    }

    func perform<Response>(owner: String, initiallyExpired: Bool,
        authenticate: @escaping @MainActor () async throws -> Void,
        retryAuthentication: @escaping @MainActor (Error) -> Bool = { _ in false },
        pauseBeforeRetry: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) },
        request: @escaping @MainActor () async throws -> Response,
        isExpired: (Response) -> Bool) async throws -> Response {
        try Task.checkCancellation()
        var recovered = initiallyExpired
        if initiallyExpired { try await recover(owner, authenticate: authenticate, mayRetry: retryAuthentication, pause: pauseBeforeRetry) }
        try Task.checkCancellation()
        var response = try await request()
        if isExpired(response) && !recovered {
            recovered = true
            try await recover(owner, authenticate: authenticate, mayRetry: retryAuthentication, pause: pauseBeforeRetry)
            try Task.checkCancellation()
            response = try await request()
        }
        // A fresh login rejected by the next request must not create a loop.
        if recovered && isExpired(response) { blocked.insert(owner) }
        return response
    }
}

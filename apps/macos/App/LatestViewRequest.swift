import Foundation

/// Only the newest request may update a view after an asynchronous operation.
struct LatestViewRequest {
    private var current: UUID?
    mutating func begin() -> UUID {
        let token = UUID()
        current = token
        return token
    }
    func contains(_ token: UUID) -> Bool { current == token }
    @discardableResult mutating func finish(_ token: UUID) -> Bool {
        guard contains(token) else { return false }
        current = nil
        return true
    }
    mutating func invalidate() { current = nil }
}

enum MacCatalogLoading {
    static func shouldLoadBeta(visible: Bool, connected: Bool, busy: Bool, loaded: Bool, failed: Bool) -> Bool {
        visible && connected && !busy && !loaded && !failed
    }
}

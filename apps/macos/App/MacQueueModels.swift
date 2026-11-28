import Foundation

struct MacQueuedOperation: Codable, Identifiable {
    enum Kind: String, Codable { case store, beta, importFile, decrypt }
    enum State: String, Codable { case pending, running, failed }
    var id = UUID()
    let kind: Kind
    let name: String
    var app: AppResult?
    var version: String?
    var bundle: String?
    var owner: String?
    var jobID: UUID?
    var file: URL?
    var bookmark: Data?
    var previousJobIDs: [UUID]?
    var decryptAfterwards = true
    var state: State = .pending
    var problem: String?

    var stage: String {
        switch kind {
        case .store: return "App Store 下载"
        case .beta: return "TestFlight 下载"
        case .importFile: return "导入原包"
        case .decrypt: return "解密 IPA"
        }
    }
    func duplicates(_ other: Self) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .store: return app?.id == other.app?.id && version == other.version && owner == other.owner
        case .beta: return bundle == other.bundle && owner == other.owner
        case .importFile: return file?.standardizedFileURL == other.file?.standardizedFileURL
        case .decrypt: return jobID == other.jobID
        }
    }
}

struct MacQueueSnapshot: Codable {
    var operations: [MacQueuedOperation] = []
    var paused = false

    mutating func recover() {
        // Restart never silently resumes a network transfer or authentication.
        if !operations.isEmpty { paused = true }
        for index in operations.indices where operations[index].state == .running {
            operations[index].state = .failed
            operations[index].problem = "上次任务中断。请检查处理记录后重试。"
        }
    }
    @discardableResult mutating func append(_ operation: MacQueuedOperation) -> Bool {
        if let index = operations.firstIndex(where: { $0.state != .failed && $0.duplicates(operation) }) {
            if operations[index].state == .pending {
                operations[index].decryptAfterwards = operations[index].decryptAfterwards || operation.decryptAfterwards
            }
            return false
        }
        if let index = operations.firstIndex(where: { $0.state == .failed && $0.duplicates(operation) }) {
            var retry = operation
            retry.id = operations[index].id
            retry.jobID = operation.jobID ?? operations[index].jobID
            operations[index] = retry
        } else { operations.append(operation) }
        return true
    }
}

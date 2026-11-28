import AppKit
import Combine
import Foundation

@MainActor final class MacProcessingQueue: ObservableObject {
    @Published private(set) var snapshot = MacQueueSnapshot()
    @Published private(set) var activeID: UUID?
    @Published private(set) var storageProblem: String?
    private weak var model: LocalLab?
    private let file: URL
    private var subscriptions: Set<AnyCancellable> = []
    private var readable = true

    init(model: LocalLab, file: URL) {
        self.model = model; self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                snapshot = try JSONDecoder().decode(MacQueueSnapshot.self, from: Data(contentsOf: file))
                for index in snapshot.operations.indices where snapshot.operations[index].state == .running {
                    if snapshot.operations[index].jobID == nil,
                       let baseline = snapshot.operations[index].previousJobIDs {
                        let candidates = model.jobs.filter { !baseline.contains($0.id) && $0.name == snapshot.operations[index].name }
                        if candidates.count == 1 { snapshot.operations[index].jobID = candidates[0].id }
                    }
                }
                snapshot.recover()
                save()
            }
        } catch { readable = false; storageProblem = "无法读取任务队列。请检查存储权限后重新打开 App。" }
        model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.startIfPossible() }
        }.store(in: &subscriptions)
        MacCommandContext.shared.$modal.sink { [weak self] _ in
            Task { @MainActor in self?.startIfPossible() }
        }.store(in: &subscriptions)
    }
    var operations: [MacQueuedOperation] { snapshot.operations }
    var paused: Bool { snapshot.paused }
    var pendingCount: Int { operations.filter { $0.state == .pending }.count }

    func setPaused(_ value: Bool) { snapshot.paused = value; save(); if !value { startIfPossible() } }
    @discardableResult func enqueue(_ operation: MacQueuedOperation) -> Bool {
        guard readable else { return false }
        let added = snapshot.append(operation)
        guard save() else { snapshot.paused = true; return false }
        startIfPossible()
        return added
    }
    func enqueueImport(_ url: URL) {
        var operation = MacQueuedOperation(kind: .importFile, name: url.deletingPathExtension().lastPathComponent)
        operation.file = url
        operation.bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        operation.decryptAfterwards = model?.credentials.isEmpty == false
        enqueue(operation)
    }
    func enqueueDecryption(_ job: LocalJob) {
        var operation = MacQueuedOperation(kind: .decrypt, name: job.name)
        operation.jobID = job.id
        enqueue(operation)
    }
    func remove(_ id: UUID) {
        guard activeID != id else { return }
        snapshot.operations.removeAll { $0.id == id }; save(); startIfPossible()
    }
    func retry(_ id: UUID) {
        guard let index = snapshot.operations.firstIndex(where: { $0.id == id && $0.state == .failed }) else { return }
        if let model, let jobID = snapshot.operations[index].jobID,
           let job = model.jobs.first(where: { $0.id == jobID }),
           model.artifact(job, clear: false) != nil {
            // Preserve a complete original rather than downloading it a second time.
            if snapshot.operations[index].kind != .decrypt && !snapshot.operations[index].decryptAfterwards {
                remove(id); return
            }
            snapshot.operations[index] = MacQueuedOperation(kind: .decrypt, name: job.name, jobID: job.id)
        } else {
            snapshot.operations[index].state = .pending; snapshot.operations[index].problem = nil
        }
        save(); startIfPossible()
    }
    func stopFollowingDecryption(_ id: UUID) {
        guard let index = snapshot.operations.firstIndex(where: { $0.id == id && $0.kind != .decrypt }) else { return }
        snapshot.operations[index].decryptAfterwards = false; save()
    }
    func waitingReason(_ operation: MacQueuedOperation) -> String? {
        guard let model else { return "任务环境不可用" }
        if operation.kind == .store || operation.kind == .beta {
            let beta = operation.kind == .beta
            guard let owner = operation.owner, model.activeProfile(beta: beta)?.owner == owner else {
                return "等待切换到 " + (operation.owner ?? "下载账户")
            }
            if beta ? !model.betaConnected : !model.canAttemptStoreOperation { return "等待账户重新登录" }
        }
        if operation.kind == .decrypt, let jobID = operation.jobID,
           let job = model.jobs.first(where: { $0.id == jobID }), !model.hasCredentials(for: job) {
            return "等待 FairPlay 凭据"
        }
        return nil
    }
    func selectRequiredAccount(_ operation: MacQueuedOperation) throws {
        guard let model, let owner = operation.owner else { return }
        let beta = operation.kind == .beta
        guard let profile = (beta ? model.accounts.beta : model.accounts.store).first(where: { $0.owner == owner }) else {
            throw LabError("请先添加此任务使用的账户：" + owner)
        }
        try model.switchAccount(profile.id, beta: beta)
        startIfPossible()
    }
    func startIfPossible() {
        guard readable, storageProblem == nil, let model, activeID == nil, !paused,
              model.action == nil, model.message == nil, !model.askingCode,
              !MacCommandContext.hasModal else { return }
        // A task waiting for credentials/account does not block unrelated ready tasks.
        guard let index = snapshot.operations.firstIndex(where: { $0.state == .pending && waitingReason($0) == nil }) else { return }
        let operation = snapshot.operations[index]
        snapshot.operations[index].state = .running
        snapshot.operations[index].previousJobIDs = model.jobs.map(\.id)
        activeID = operation.id
        guard save() else { activeID = nil; snapshot.operations[index].state = .pending; snapshot.paused = true; return }
        model.action = operation.stage
        Task { await execute(operation, model: model) }
    }
    private func execute(_ operation: MacQueuedOperation, model: LocalLab) async {
        let previousIDs = Set(model.jobs.map(\.id))
        do {
            let replacing = operation.jobID.flatMap { id in model.jobs.first { $0.id == id } }
            let result: LocalJob?
            switch operation.kind {
            case .store:
                guard let app = operation.app else { throw LabError("任务缺少应用信息，请重新选择应用。") }
                result = try await model.download(app, version: operation.version, replacing: replacing, automaticallyDecrypt: false)
            case .beta:
                guard let bundle = operation.bundle else { throw LabError("任务缺少 Bundle ID。") }
                result = try await model.downloadBeta(operation.name, bundle: bundle, replacing: replacing, automaticallyDecrypt: false)
            case .importFile:
                var url = operation.file
                if let bookmark = operation.bookmark {
                    var stale = false
                    url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                }
                guard let url else { throw LabError("请重新选择要导入的 IPA 文件。") }
                result = try await model.importIPA(url, replacing: replacing, automaticallyDecrypt: false)
            case .decrypt:
                guard let job = replacing else { throw LabError("原处理记录已移除。") }
                try await model.decrypt(job); result = nil
            }
            let follow = snapshot.operations.first(where: { $0.id == operation.id })?.decryptAfterwards == true
            snapshot.operations.removeAll { $0.id == operation.id }
            if follow, let result { _ = snapshot.append(MacQueuedOperation(kind: .decrypt, name: result.name, jobID: result.id)) }
        } catch {
            if let index = snapshot.operations.firstIndex(where: { $0.id == operation.id }) {
                snapshot.operations[index].state = .failed
                snapshot.operations[index].problem = model.friendly(error)
                if operation.kind != .decrypt {
                    snapshot.operations[index].jobID = operation.jobID ?? model.jobs.first(where: { !previousIDs.contains($0.id) })?.id
                }
            }
        }
        save(); activeID = nil; model.action = nil
        startIfPossible()
    }
    @discardableResult private func save() -> Bool {
        guard readable else { return false }
        do {
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageProblem = nil
            return true
        } catch { storageProblem = "无法保存任务队列，已停止启动新任务。请检查存储权限与可用空间。"; return false }
    }
}

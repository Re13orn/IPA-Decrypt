import SwiftUI

@MainActor struct MacQueuePanel: View {
    @ObservedObject var model: LocalLab
    @ObservedObject var queue: MacProcessingQueue
    let prepareCredentials: (LocalJob) -> Void
    let manageAccount: (MacQueuedOperation) -> Void
    @State private var expanded = true

    private var title: String {
        let failed = queue.operations.filter { $0.state == .failed }.count
        if queue.pendingCount > 0 { return "任务队列 · \(queue.pendingCount) 项待执行" + (failed > 0 ? " · \(failed) 项需处理" : "") }
        return queue.activeID != nil ? "任务队列 · 正在处理" : "任务队列 · \(failed) 项需处理"
    }
    private func status(_ operation: MacQueuedOperation) -> String {
        if let message = operation.problem ?? queue.waitingReason(operation) { return message }
        let stage = operation.state == .running ? operation.stage : "排队 · " + operation.stage
        return operation.kind == .decrypt ? stage : stage + (operation.decryptAfterwards ? " → 解密" : " · 仅保存原包")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    Text(title).font(.headline)
                }.fixedSize()
                Spacer()
                Button(queue.paused ? "继续队列" : "暂停队列", systemImage: queue.paused ? "play" : "pause") {
                    queue.setPaused(!queue.paused)
                }.help("暂停后，当前步骤完成并保存文件；其他任务等待继续。")
            }
            if let problem = queue.storageProblem { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            if expanded {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(queue.operations) { operation in
                            HStack(spacing: 12) {
                                if operation.state == .running { ProgressView().controlSize(.small) }
                                else { Image(systemName: operation.state == .failed ? "exclamationmark.circle" : "clock").foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(operation.name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(status(operation))
                                        .font(.caption).foregroundStyle(operation.state == .failed ? .red : .secondary).lineLimit(2)
                                        .help(operation.problem ?? queue.waitingReason(operation) ?? operation.stage).textSelection(.enabled)
                                    if let owner = operation.owner { Text(operation.stage + " · " + owner).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                                Spacer()
                                if operation.state == .failed {
                                    if operation.kind == .decrypt, let id = operation.jobID, let job = model.jobs.first(where: { $0.id == id }) {
                                        Button("更换凭据") { prepareCredentials(job) }
                                    }
                                    Button("重试") { queue.retry(operation.id) }
                                }
                                if operation.state == .pending, queue.waitingReason(operation) != nil {
                                    if operation.kind == .decrypt, let jobID = operation.jobID, let job = model.jobs.first(where: { $0.id == jobID }) {
                                        Button("获取凭据") { prepareCredentials(job) }
                                    } else { Button("选择账户…") { manageAccount(operation) }.disabled(model.action != nil) }
                                }
                                if operation.state != .running {
                                    Button(operation.state == .failed ? "移除" : "取消") { queue.remove(operation.id) }
                                        .help("仅移除队列项，保留已保存的 IPA 和处理记录。")
                                } else if operation.kind != .decrypt && operation.decryptAfterwards {
                                    Button("停止后续解密") { queue.stopFollowingDecryption(operation.id) }
                                        .help("当前下载或导入仍会完成，原包会保留。")
                                }
                            }
                            if operation.id != queue.operations.last?.id { Divider() }
                        }
                    }.padding(.vertical, 4)
                }.frame(height: min(CGFloat(queue.operations.count) * 76, 210))
            }
        }.padding(16).background(.bar)
    }
}

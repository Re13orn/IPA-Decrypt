import SwiftUI

struct MacDownloadPlan: Identifiable {
    let id = UUID()
    let name: String
    var app: AppResult?
    var bundle: String?
    var version: String?
    var replacing: LocalJob?
    var decryptAfterwards = true
    var beta: Bool { app == nil }
    var service: String { beta ? "TestFlight" : "App Store" }

    func operation(owner: String, decrypt: Bool) -> MacQueuedOperation {
        var value = MacQueuedOperation(kind: beta ? .beta : .store, name: name)
        value.app = app; value.bundle = bundle; value.version = version
        value.jobID = replacing?.id; value.owner = owner; value.decryptAfterwards = decrypt
        return value
    }
}

@MainActor struct MacDownloadPreparation: View {
    @ObservedObject var model: LocalLab
    let plan: MacDownloadPlan
    let enqueue: (Bool) -> Void
    let credentials: (Bool) -> Void
    let accounts: (Bool) -> Void
    let cancel: () -> Void
    @State private var decrypt = true
    private var connected: Bool { plan.beta ? model.betaConnected : model.canAttemptStoreOperation }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("准备下载").font(.title2.bold())
            if let app = plan.app { AppListingLabel(app: app) }
            else { Label(plan.name, systemImage: "app.badge").font(.headline) }
            VStack(spacing: 16) {
                GroupBox("下载账户") {
                    VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("服务", value: plan.service)
                    LabeledContent("账户", value: model.activeProfile(beta: plan.beta)?.email ?? "未选择")
                    if let version = plan.version { LabeledContent("版本 ID", value: version).font(.callout.monospacedDigit()) }
                    Button(connected ? "切换账户…" : "登录 " + plan.service + "…") { accounts(decrypt) }
                        .disabled(model.action != nil)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("处理方式") {
                    VStack(alignment: .leading, spacing: 10) {
                    Picker("下载后", selection: $decrypt) {
                        Text("尝试解密").tag(true)
                        Text("仅保存原包").tag(false)
                    }.pickerStyle(.segmented)
                    if model.credentials.isEmpty {
                        Label("尚未添加 FairPlay 凭据", systemImage: "key").foregroundStyle(.secondary)
                        Text(decrypt ? "原包会先保存，解密任务等待凭据准备完成。" : "下载后可随时添加凭据，再继续解密。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("已保存 \(model.credentials.count) 个凭据", systemImage: "key.fill")
                        Text("下载后按实际许可证匹配；账户标签不代表已验证兼容。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("先获取或导入凭据…") { credentials(decrypt) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if model.askingCode {
                Label("当前任务需要验证码，请先关闭此窗口完成验证。", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("加入任务队列") { enqueue(decrypt) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!connected || model.askingCode)
            }
        }.padding(24).frame(width: 540, height: 570)
        .onAppear { decrypt = plan.decryptAfterwards }
    }
}

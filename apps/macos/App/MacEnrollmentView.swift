import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct MacEnrollmentView: View {
    @ObservedObject var model: LocalLab
    let viewCredential: (UUID) -> Void
    let useCredentials: () -> Void
    var continuationTitle: String? = nil
    @State private var savedID: UUID?
    @State private var apps: [InstalledMacIOSApp] = []
    @State private var selected: String?
    @State private var owner: String?
    @State private var task: Task<MacEnrollment.Recovered, Error>?
    @State private var status: String?
    @State private var failed = false
    private var busy: Bool { task != nil }
    private var selectedApp: InstalledMacIOSApp? { apps.first { $0.id == selected } }
    var body: some View {
        Form {
            Section {
                Label("从这台 Mac 提取 FairPlay 模型", systemImage: "desktopcomputer").font(.title2.bold())
                Text("先从 Mac App Store 安装并打开一个 iPhone / iPad App，再选择它提取模型。").foregroundStyle(.secondary)
            }
            Section("1. 选择已安装的 iPhone / iPad 应用") {
                HStack {
                    Button("刷新列表", systemImage: "arrow.clockwise") { refresh() }
                    Button("选择其他应用…", systemImage: "folder") { chooseApp() }
                }.disabled(busy)
                Text("已找到 \(apps.count) 个带许可证的应用；包含应用目录的子文件夹。").font(.caption).foregroundStyle(.secondary)
                if apps.isEmpty {
                    Text("未找到带有 FairPlay 许可证的 iOS App。请从原生 Mac App Store 安装并打开一个 iPhone 或 iPad App。").foregroundStyle(.secondary)
                } else {
                    ForEach(apps) { app in
                        Button { selected = app.id } label: {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 36, height: 36)
                                VStack(alignment: .leading) { Text(app.name); Text(app.url.path).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Image(systemName: selected == app.id ? "checkmark.circle.fill" : "circle").foregroundStyle(selected == app.id ? Color.accentColor : .secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy)
                    }
                }
            }
            Section("2. 提取并验证") {
                Picker("归属 Apple ID（管理标签）", selection: $owner) {
                    Text("未绑定").tag(nil as String?)
                    ForEach(model.credentialOwners, id: \.self) { Text($0).tag(Optional($0)) }
                }.disabled(busy)
                Text("系统会请求管理员授权，用于读取本机注册信息；验证通过后保存模型。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("提取并验证模型", systemImage: "key.fill") { extract() }.buttonStyle(.borderedProminent).disabled(busy || selectedApp == nil || model.action != nil)
                    if busy { ProgressView().controlSize(.small); Text("正在提取并验证…").font(.callout); Button("取消") { task?.cancel() } }
                }
                if let status { Text(status).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
            }
            if let savedID {
                Section("3. 用于解密") {
                    HStack {
                        Button(continuationTitle ?? (model.jobs.isEmpty ? "下载 IPA" : "选择 IPA 解密"), systemImage: "lock.open", action: useCredentials).buttonStyle(.borderedProminent)
                        Button("查看已保存模型") { viewCredential(savedID) }
                    }
                    Text("下载或导入 IPA 后自动尝试匹配；已有文件可在处理记录中继续解密。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("使用范围") {
                Text("适用于与这台 Mac 注册状态匹配的 IPA；解密时会再次校验许可证。")
                Text("本机模型仅供 Mac 版使用。传到 iPhone 使用的 credential.bin，需从越狱设备提取。")
            }.foregroundStyle(.secondary)
        }.formStyle(.grouped)
        .onAppear { refresh() }
        .onDisappear { task?.cancel() }
    }
    private func refresh() { apps = MacEnrollment.installedApps(); if !apps.contains(where: { $0.id == selected }) { selected = apps.first?.id } }
    private func chooseApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try MacEnrollment.normalizedApp(url)
            if !apps.contains(where: { $0.url == url }) { apps.append(.init(url: url, name: url.deletingPathExtension().lastPathComponent)) }
            selected = url.path; status = nil
        } catch { failed = true; status = model.friendly(error) }
    }
    private func extract() {
        guard let app = selectedApp, model.action == nil else { return }
        do {
            let resources = try MacEnrollment.resources(), label = owner
            failed = false; status = nil; savedID = nil; model.action = "正在提取本机模型"
            let operation = Task.detached(priority: .userInitiated) { try MacEnrollment.recover(app: app, resources: resources) }
            task = operation
            Task {
                defer { task = nil; model.action = nil }
                do {
                    let result = try await operation.value
                    if operation.isCancelled { throw CancellationError() }
                    savedID = try model.addEnrollmentModel(result.data, owner: label, origin: "本机恢复", appName: result.appName, verified: result.verified)
                    status = result.verified ? "模型已保存，已通过所选应用的解密与完整性校验。" : "模型已保存并通过解密验证；部分映像缺少明文哈希，未标记为全部明文校验通过。"
                } catch is CancellationError { status = "已取消，临时文件已清理。" }
                catch { failed = true; status = model.friendly(error) }
            }
        } catch { failed = true; status = model.friendly(error) }
    }
}

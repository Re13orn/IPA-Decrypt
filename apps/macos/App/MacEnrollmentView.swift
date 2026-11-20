import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct MacEnrollmentView: View {
    @ObservedObject var model: LocalLab
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
                Text("在原生 Mac App Store 登录，安装并打开一个 iPhone 或 iPad App，再从下方选择该应用。提取会读取本机注册状态，并用所选应用完整验证恢复的模型，无需越狱设备。").foregroundStyle(.secondary)
            }
            Section("选择验证应用") {
                HStack {
                    Button("刷新列表", systemImage: "arrow.clockwise") { refresh() }
                    Button("选择其他应用…", systemImage: "folder") { chooseApp() }
                }.disabled(busy)
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
            Section("保存与提取") {
                Picker("归属 Apple ID（管理标签）", selection: $owner) {
                    Text("未绑定").tag(nil as String?)
                    ForEach(model.credentialOwners, id: \.self) { Text($0).tag(Optional($0)) }
                }.disabled(busy)
                Text("首次读取系统注册文件时会弹出 macOS 管理员授权窗口。管理员密码由系统处理，App 不接收或保存。原始快照及临时验证文件在本次操作结束后清理，只保存通过验证的模型。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("提取并验证模型", systemImage: "key.fill") { extract() }.buttonStyle(.borderedProminent).disabled(busy || selectedApp == nil || model.action != nil)
                    if busy { ProgressView().controlSize(.small); Text("正在提取并验证…").font(.callout); Button("取消") { task?.cancel() } }
                }
                if let status { Text(status).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
            }
            Section("使用范围") {
                Text("恢复的模型可解密与本机商店注册状态及许可证匹配的 IPA。相同 Apple ID 并不保证所有下载来源都匹配；下载后会按许可证实际校验。")
                Text("模型可在“FairPlay 凭据”中查看、改名、设置管理归属、导出或删除。已有 credential.bin 仍可正常使用。")
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
            failed = false; status = nil; model.action = "正在提取本机模型"
            let operation = Task.detached(priority: .userInitiated) { try MacEnrollment.recover(app: app, resources: resources) }
            task = operation
            Task {
                defer { task = nil; model.action = nil }
                do {
                    let result = try await operation.value
                    if operation.isCancelled { throw CancellationError() }
                    _ = try model.addEnrollmentModel(result.data, owner: label, origin: "本机恢复", appName: result.appName, verified: result.verified)
                    status = result.verified ? "模型已保存，完整解密及明文哈希校验通过。可在 FairPlay 凭据中管理。" : "模型已保存并通过解密验证；部分映像缺少明文哈希，未标记为全部明文校验通过。"
                } catch is CancellationError { status = "已取消，临时文件已清理。" }
                catch { failed = true; status = model.friendly(error) }
            }
        } catch { failed = true; status = model.friendly(error) }
    }
}

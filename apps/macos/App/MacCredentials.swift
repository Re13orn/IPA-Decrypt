import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct MacCredentials: View {
    @ObservedObject var model: LocalLab
    @Binding var incomingFile: URL?
    @Binding var selected: UUID?
    let extractLocal: () -> Void
    let extractDevice: () -> Void
    let useCredentials: () -> Void
    @State private var query = ""
    @State private var importing = false
    @State private var pendingFile: URL?
    @State private var status: String?

    private var groups: [CredentialGroup] {
        CredentialGroup.make(records: model.credentials, accounts: model.credentialOwners).compactMap { group in
            guard !query.isEmpty else { return group }
            let accountMatches = group.title.localizedStandardContains(query)
            let records = group.records.filter { accountMatches || $0.displayName.localizedStandardContains(query) || $0.fingerprint.localizedStandardContains(query) }
            return !records.isEmpty || accountMatches ? CredentialGroup(owner: group.owner, records: records) : nil
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.credentials.count) 个凭据 · \(Set(model.credentials.compactMap(\.owner)).count) 个账户标签").font(.headline)
                    Text("解密时自动按许可证匹配；账户标签用于归类。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("获取凭据") {
                    Button("从这台 Mac 提取模型", systemImage: "desktopcomputer", action: extractLocal)
                    Button("从越狱设备提取凭据", systemImage: "iphone.and.arrow.forward", action: extractDevice)
                }
                if !model.credentials.isEmpty { Button(model.jobs.isEmpty ? "下载或导入 IPA" : "选择 IPA 解密", systemImage: "lock.open", action: useCredentials) }
                Button("导入已有凭据", systemImage: "plus") { pendingFile = nil; importing = true }.buttonStyle(.borderedProminent)
            }.padding()
            Divider()
            if model.credentials.isEmpty {
                ContentUnavailableView {
                    Label("获取用于解密的凭据", systemImage: "key")
                } description: {
                    Text("这台 Mac 已安装商店中的 iPhone / iPad App，可尝试本机提取；有越狱设备可提取 credential.bin。")
                } actions: {
                    Button("从本机提取", action: extractLocal).buttonStyle(.borderedProminent)
                    Button("从越狱设备提取", action: extractDevice)
                }
            } else {
            HSplitView {
                VStack(spacing: 0) {
                    TextField("搜索 Apple ID、名称或指纹", text: $query).textFieldStyle(.roundedBorder).padding(12)
                    if groups.isEmpty {
                        ContentUnavailableView("没有匹配的凭据", systemImage: "magnifyingglass", description: Text("尝试其他 Apple ID、名称或指纹。"))
                    }
                    List(selection: $selected) {
                        ForEach(groups) { group in
                            Section {
                                if group.records.isEmpty { Text("尚无凭据").font(.caption).foregroundStyle(.secondary) }
                                ForEach(group.records) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Label(item.displayName, systemImage: item.isEnrollment ? "desktopcomputer" : "key")
                                        Text(item.formatName).font(.caption).foregroundStyle(.secondary)
                                        Text(item.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        if model.credentials.contains(where: { $0.id != item.id && $0.data == item.data }) {
                                            Text("其他归属下也有相同内容").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 5).tag(item.id)
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.title).textCase(nil)
                                    Text("\(group.records.count) 个凭据").font(.caption2)
                                }
                            }
                        }
                    }.listStyle(.sidebar)
                }.frame(minWidth: 270, idealWidth: 330, maxWidth: 420)
                Group {
                    if let selected, let record = model.credentials.first(where: { $0.id == selected }) {
                        CredentialDetail(model: model, record: record) { status = $0 }
                            .id(record.id)
                    } else {
                        ContentUnavailableView("选择一个凭据", systemImage: "key", description: Text("左侧按 Apple ID 列出凭据，未绑定的凭据单独显示。"))
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            if let status { Divider(); Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
        }
        .sheet(isPresented: $importing, onDismiss: { pendingFile = nil }) {
            CredentialImportSheet(model: model, incoming: pendingFile) { id in selected = id; query = ""; status = "凭据已保存。" }
        }
        .onAppear { if selected == nil { selected = model.credentials.first?.id }; receiveIncoming() }
        .onChange(of: incomingFile) { receiveIncoming() }
        .onChange(of: model.credentials.map(\.id)) {
            if !model.credentials.contains(where: { $0.id == selected }) { selected = model.credentials.first?.id }
        }
    }
    private func receiveIncoming() {
        guard let url = incomingFile else { return }
        pendingFile = url; incomingFile = nil; importing = true
    }
}

@MainActor private struct CredentialDetail: View {
    @ObservedObject var model: LocalLab
    let record: FairPlayCredential
    let status: (String) -> Void
    @State private var reveal = false
    @State private var name = ""
    @State private var assigning = false
    @State private var deleting = false
    @State private var showMetadata = false
    @State private var showVerification = false

    private var matching: [FairPlayCredential] { model.credentials.filter { $0.id != record.id && $0.data == record.data } }
    var body: some View {
        Form {
            Section {
                Label(record.displayName, systemImage: record.isEnrollment ? "desktopcomputer" : "key.fill").font(.title2.bold())
                Text(record.formatName).font(.callout).foregroundStyle(.secondary)
                LabeledContent("归属 Apple ID", value: record.owner ?? "未绑定")
                Button("更改归属 Apple ID…") { assigning = true }
                TextField("名称或备注", text: $name, prompt: Text("例如：常用 App 凭据、测试版凭据"))
                Button("保存名称") { attempt { try model.renameCredential(record.id, label: name) } }
                    .disabled(name == (record.label ?? ""))
            }
            Section("凭据内容") {
                if record.isEnrollment {
                    LabeledContent("格式", value: "Mac FairPlay 注册模型")
                    LabeledContent("大小", value: "\(record.data.count) 字节")
                    if let selector = record.enrollmentSelector { LabeledContent("许可证 user / key", value: selector).font(.callout.monospaced()) }
                    if let app = record.sourceApp { LabeledContent("验证应用", value: app) }
                    LabeledContent("明文哈希校验", value: record.plaintextVerified == true ? "已通过" : "待使用匹配 IPA 验证")
                    Button("导出本机模型…", systemImage: "square.and.arrow.up") { export() }
                    Text("模型按实际许可证匹配；Apple ID 仅用于管理归属。模型不是 16 字节 credential.bin，不能转换为该格式使用。").font(.caption).foregroundStyle(.secondary)
                } else {
                HStack {
                    Text(reveal ? record.hex : "••••••••••••••••••••••••••••••••")
                        .font(.body.monospaced()).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .help(reveal ? "隐藏十六进制" : "查看十六进制")
                }
                HStack {
                    Button("复制十六进制", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.hex, forType: .string)
                        status("已复制 32 位十六进制凭据。")
                    }
                    Button("导出 credential.bin…", systemImage: "square.and.arrow.up") { export() }
                }
                Text("16 字节凭据可写成 32 位十六进制字符。这里的文本与 credential.bin 保存的是同一份数据，可用于粘贴导入。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("来源与识别信息", isExpanded: $showMetadata) {
                LabeledContent("SHA-256 短指纹", value: record.fingerprint).font(.callout.monospaced())
                Text("短指纹用于识别相同内容，不是凭据本身。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("来源", value: record.origin ?? "旧版凭据，来源未记录")
                if let date = record.addedAt { LabeledContent("添加时间", value: date.formatted(date: .abbreviated, time: .shortened)) }
                else { LabeledContent("添加时间", value: "旧版数据，时间未知") }
                if !matching.isEmpty {
                    Text("相同内容也保存在：" + matching.map { $0.owner ?? "未绑定" }.sorted().joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Apple ID 归属是你设置的管理标签，不能据此判断许可证适用性。同一账户可能需要多个凭据或模型。").font(.caption).foregroundStyle(.secondary)
            }
            }
            Section {
                DisclosureGroup("许可证校验记录", isExpanded: $showVerification) {
                if let proofs = record.verifiedLicenses, !proofs.isEmpty {
                    ForEach(Array(proofs.enumerated()), id: \.offset) { _, proof in
                        LabeledContent("实际触发 App", value: proof.appName + " · " + proof.bundleID)
                        LabeledContent("目标许可证", value: "user " + proof.user + " / key " + proof.key).font(.callout.monospaced())
                        if proof.triggerKey != proof.key { LabeledContent("同账户触发许可证 key", value: proof.triggerKey).font(.callout.monospaced()) }
                    }
                    Text("提取结果已通过以上目标 IPA 的许可证校验。user / key 是许可证选择标识，不是凭据内容。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("尚未记录目标许可证校验。此记录的账户归属为手动标签或旧版数据，不能据此证明实际来源账户。").foregroundStyle(.secondary)
                }
            }
            }
            Section { Button("删除此凭据…", systemImage: "trash", role: .destructive) { deleting = true } }
        }.formStyle(.grouped)
        .onAppear { name = record.label ?? "" }
        .onChange(of: record.label) { name = record.label ?? "" }
        .onDisappear { reveal = false }
        .sheet(isPresented: $assigning) { CredentialAssignment(model: model, record: record, status: status) }
        .alert("删除此凭据记录？", isPresented: $deleting) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { attempt { try model.removeCredential(record.id) } }
        } message: { Text("将从本机凭据库移除“\(record.displayName)”（\(record.owner ?? "未绑定")）。") }
    }
    private func attempt(_ operation: () throws -> Void) { do { try operation(); status("更改已保存。") } catch { status(model.friendly(error)) } }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (record.isEnrollment ? "fairplay-model-" : "credential-") + String(record.fingerprint.prefix(8)) + ".bin"
        if panel.runModal() == .OK, let url = panel.url {
            attempt { try record.data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        }
    }
}

@MainActor private struct CredentialAssignment: View {
    @ObservedObject var model: LocalLab
    let record: FairPlayCredential
    let status: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var custom = ""
    @State private var problem: String?
    private var target: String? {
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return typed.isEmpty ? selected : typed
    }
    private var duplicate: Bool { model.credentials.contains { $0.id != record.id && $0.owner == target && $0.data == record.data } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更改凭据归属").font(.title2.bold())
            Text(record.displayName).foregroundStyle(.secondary)
            Picker("Apple ID", selection: $selected) {
                Text("未绑定").tag(nil as String?)
                ForEach(model.credentialOwners, id: \.self) { Text($0).tag(Optional($0)) }
            }
            TextField("或输入其他 Apple ID", text: $custom).textFieldStyle(.roundedBorder)
            if duplicate { Text("目标账户已保存相同内容。保存后合并这两条重复记录，保留目标账户现有记录。").font(.callout).foregroundStyle(.orange) }
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(duplicate ? "确认合并归属" : "保存归属") {
                do {
                    if let target, target.contains(where: \.isWhitespace) { throw LabError("Apple ID 不能包含空格。") }
                    try model.moveCredential(record.id, to: target)
                    status(duplicate ? "重复内容已合并到目标账户。" : "凭据归属已更新。")
                    dismiss()
                } catch { problem = model.friendly(error) }
            }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 500).onAppear { selected = record.owner }
    }
}

@MainActor private struct CredentialImportSheet: View {
    @ObservedObject var model: LocalLab
    let incoming: URL?
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var owner: String?
    @State private var hex = ""
    @State private var label = ""
    @State private var reading = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入 FairPlay 凭据").font(.title2.bold())
            Picker("归属 Apple ID", selection: $owner) {
                Text("未绑定").tag(nil as String?)
                ForEach(model.credentialOwners, id: \.self) { Text($0).tag(Optional($0)) }
            }
            TextField("名称或备注（可选）", text: $label).textFieldStyle(.roundedBorder)
            Button(incoming == nil ? "选择 credential.bin 或本机模型…" : "导入收到的 " + incoming!.lastPathComponent, systemImage: "doc.badge.plus") {
                if let incoming { importFile(incoming) }
                else { let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; if panel.runModal() == .OK, let url = panel.url { importFile(url) } }
            }.disabled(reading)
            Divider()
            Text("或粘贴 32 位十六进制凭据").font(.headline)
            SecureField("支持 0x 前缀与空格", text: $hex).textFieldStyle(.roundedBorder)
            Text("credential.bin 为 16 字节，对应 32 个十六进制字符。Mac 本机模型请通过文件导入。").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            if reading { ProgressView("正在读取…") }
            HStack {
                Button("取消") { dismiss() }.disabled(reading).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存十六进制凭据") {
                    do { let id = try model.addCredential(hex: hex, owner: owner); finish(id: id) }
                    catch { problem = model.friendly(error) }
                }.buttonStyle(.borderedProminent).disabled(reading || hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
        .onAppear { owner = model.activeProfile(beta: false)?.owner ?? model.activeProfile(beta: true)?.owner }
    }
    private func finish(id: UUID) {
        guard let record = model.credentials.first(where: { $0.id == id }) else { return }
        do {
            if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try model.renameCredential(record.id, label: label) }
            saved(record.id); hex = ""; dismiss()
        } catch { problem = model.friendly(error) }
    }
    private func importFile(_ url: URL) {
        reading = true
        Task {
            defer { reading = false }
            do {
                let data = try await Task.detached {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == 16 { return try CredentialFileReader.read(url) }
                    let data = try MacEnrollment.readModel(url); _ = try MacEnrollment.inspect(data, resources: MacEnrollment.resources()); return data
                }.value
                let id = data.count == 16 ? try model.addCredential(data, owner: owner) : try model.addEnrollmentModel(data, owner: owner, origin: "模型文件导入")
                finish(id: id)
            }
            catch { problem = model.friendly(error) }
        }
    }
}

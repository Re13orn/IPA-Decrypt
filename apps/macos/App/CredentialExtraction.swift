import AppKit
import Foundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

enum ExtractorProcess {
    struct Reply: Decodable { var devices: [JailbreakDevice]?; var path: String?; var error: String?; var message: String?; var licenses: [ExtractionLicense]?; var selection: CredentialLicenseEvidence?; var installedLicenses: [InstalledLicense]? }
    static func execute(_ arguments: [String], password: String = "", privateKey: URL? = nil, rootPassword: String = "") async throws -> Reply {
        try await Task.detached(priority: .userInitiated) {
            guard let resources = Bundle.main.resourceURL else { throw LabError("找不到设备提取组件。") }
            let python = resources.appendingPathComponent("Python/bin/python3")
            let process = Process()
            process.executableURL = python
            process.arguments = [resources.appendingPathComponent("Extractor/host.py").path] + arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = resources.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            env["PYTHONHOME"] = resources.appendingPathComponent("Python").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONPATH"] = ""
            env["IPA_SSH_PASSWORD"] = password
            env["IPA_ROOT_PASSWORD"] = rootPassword
            if let privateKey { env["IPA_SSH_KEY"] = privateKey.path }
            process.environment = env
            let output = Pipe(); process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard data.count < 1_048_576, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw LabError("设备提取组件未返回有效结果。") }
            if let error = reply.error { throw LabError(error) }
            guard process.terminationStatus == 0 else { throw LabError("设备提取失败。") }
            return reply
        }.value
    }
}

@MainActor struct CredentialExtractionView: View {
    @ObservedObject var model: LocalLab
    let viewCredential: (UUID) -> Void
    let useCredentials: () -> Void
    @State private var devices: [JailbreakDevice] = []
    @AppStorage("device-selected-udid") private var selected = ""
    @AppStorage("device-connection-mode") private var mode = "usb"
    @AppStorage("device-ssh-host") private var host = ""
    @AppStorage("device-ssh-port") private var port = "22"
    @State private var testing = false
    @State private var tested: String?
    @State private var password = ""
    @State private var revealPassword = false
    @AppStorage("device-elevation-method") private var elevation = "auto"
    @State private var rootPassword = ""
    @State private var revealRootPassword = false
    @AppStorage("device-ssh-user") private var username = "root"
    @State private var privateKey: URL?
    @State private var license: URL?
    @State private var targetJob: UUID?
    @State private var externalSource = false
    @State private var choices: [ExtractionLicense] = []
    @State private var member = ""
    @State private var inspecting = false
    @State private var inspectionID = UUID()
    @State private var installed: [InstalledLicense] = []
    @State private var selectedLicenseID: String?
    @State private var search = ""
    @State private var scannedSignature: String?
    @State private var automaticAuthentication = true
    @State private var accountReferences: [DownloadLicenseReference] = []
    @State private var snapshotFolder: URL?
    @State private var batchRunning = false
    @State private var stopRequested = false
    @State private var failures: [String: String] = [:]
    @State private var selectedCredentialID: String?
    @State private var batchProgress = 0
    @State private var batchTotal = 0
    @State private var output: URL?
    @State private var owner: String? = nil
    @State private var busy = false
    @State private var discovering = false
    @State private var status: String?
    @State private var succeeded = false

    var body: some View {
        Form {
            Section {
                Label("从越狱设备提取凭据", systemImage: "iphone.and.arrow.forward").font(.title2.bold())
                Text("连接已越狱设备并测试 SSH，再点“全部提取并去重”。设备上需安装 App Store App。").foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("连接要求") {
                    Text("设备需已越狱并开启 SSH。USB 连接仍需 SSH 认证；也可使用 IP 地址连接。")
                    Text("设备上需安装 App Store App。提取期间会临时运行关联应用，完成后清理临时文件。")
                }.font(.callout).foregroundStyle(.secondary)
            }
            Section("1. 连接越狱设备") {
                Picker("连接", selection: $mode) {
                    Text("USB 设备").tag("usb")
                    Text("IP / 主机名").tag("network")
                }.pickerStyle(.segmented)
                if mode == "usb" {
                    HStack {
                        Picker("已连接设备", selection: $selected) {
                            Text(devices.isEmpty ? "未检测到 USB 设备" : "请选择设备").tag("")
                            ForEach(devices) { Text($0.name + " · iOS " + $0.version).tag($0.id) }
                        }
                        Button("刷新") { discover() }.disabled(discovering)
                    }
                    if discovering { ProgressView("正在读取设备信息…") }
                } else {
                    TextField("设备 IP 或主机名", text: $host, prompt: Text("192.168.1.100 或 iphone.local"))
                    Text("Mac 与设备需能通过网络互通，无需 USB 连接或填写 UDID。").font(.caption).foregroundStyle(.secondary)
                }
                TextField("设备 SSH 端口", text: $port).frame(maxWidth: 250)
                Text("默认 22；部分设备使用 44。USB 方式会自动建立和关闭转发。").font(.caption).foregroundStyle(.secondary)
            }.disabled(busy || testing)
            Section("2. 测试连接") {
                Toggle("自动尝试常见账户组合", isOn: $automaticAuthentication)
                Text("开启后只尝试 root/alpine 与 mobile/123456；关闭后使用下方填写的信息。").font(.caption).foregroundStyle(.secondary)
                TextField("SSH 用户名", text: $username)
                HStack {
                    Group {
                        if revealPassword { TextField("密码或私钥口令", text: $password) }
                        else { SecureField("密码或私钥口令", text: $password) }
                    }
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }.buttonStyle(.borderless).help(revealPassword ? "隐藏密码" : "显示密码")
                }
                HStack { Text(privateKey?.lastPathComponent ?? "使用默认 SSH 密钥").foregroundStyle(.secondary); Spacer(); Button("选择私钥…") { privateKey = choose() }; if privateKey != nil { Button("清除") { privateKey = nil } } }
                Picker("提权方式", selection: $elevation) {
                    Text("自动（sudo → su）").tag("auto")
                    Text("sudo").tag("sudo")
                    Text("su（切换 root）").tag("su")
                }
                if elevation != "sudo" {
                    HStack {
                        Group { if revealRootPassword { TextField("root 密码（su，可选）", text: $rootPassword) } else { SecureField("root 密码（su，可选）", text: $rootPassword) } }
                        Button { revealRootPassword.toggle() } label: { Image(systemName: revealRootPassword ? "eye.slash" : "eye") }.buttonStyle(.borderless).help("查看或隐藏 root 密码")
                    }
                    Text("sudo 验证当前 SSH 用户；su 验证 root。root 密码留空时仅尝试 SSH 密码，不额外猜测其他密码。").font(.caption).foregroundStyle(.secondary)
                }
                Text("SSH 与 root 密码仅用于本次操作，不保存；设备身份记录按设备隔离。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(testing ? "正在测试…" : "测试连接", systemImage: "network") { testConnection() }
                        .disabled(busy || testing || !validConnection)
                    if tested == signature { Label("连接已验证", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }.disabled(busy || testing)
            Section {
                DisclosureGroup("为指定 IPA 匹配来源（可选）") {
                Picker("目标 Apple ID", selection: $owner) {
                    Text("未选择账户 / 外部 IPA").tag(nil as String?)
                    ForEach(model.credentialOwners, id: \.self) { Text($0).tag(Optional($0)) }
                }
                if !accountJobs.isEmpty {
                    Picker("该账户下载的原始 IPA", selection: $targetJob) {
                        Text("请选择 / 使用外部 IPA").tag(nil as UUID?)
                        ForEach(accountJobs) { Text($0.name + ($0.version.map { " · " + $0 } ?? "")).tag(Optional($0.id)) }
                    }
                } else {
                    Text("该账户暂无本机原始 IPA。仍可选择手机上的许可证提取，结果保存为未绑定。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(license?.lastPathComponent ?? "未选择目标 IPA（仍可扫描并提取设备许可证）").foregroundStyle(.secondary)
                    Spacer()
                    Button("选择外部 IPA…") { if let url = choose(ipa: true) { externalSource = true; targetJob = nil; inspect(url) } }
                }
                if inspecting { ProgressView("正在读取目标许可证…") }
                if !choices.isEmpty {
                    Picker("目标许可证", selection: $member) {
                        ForEach(choices) { Text($0.member + " · user " + $0.user + " / key " + $0.key).tag($0.member) }
                    }
                    Text("匹配此 IPA 的设备许可证会标为推荐；仍需你从设备列表中选择。").font(.caption).foregroundStyle(.secondary)
                    Text(targetJob == nil ? "外部 IPA 的下载账户未知，结果保存为未绑定。" : "保存归属依据该任务的下载账户；不会用界面标签推测许可证账户。").font(.caption).foregroundStyle(.secondary)
                }
                }
            }.disabled(busy || testing)
            Section("3. 提取并保存") {
                Text("全部提取会自动扫描、提取并合并相同内容；扫描许可证用于先查看来源。已确认的凭据会自动保存。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(busy ? "正在处理…" : "扫描许可证", systemImage: "arrow.clockwise") { scan() }
                        .disabled(busy || testing || !validConnection)
                    Text("\(confirmedGroups.count) 个已确认凭据 · \(pendingSupported.count) 条待识别 · \(unsupportedCount) 条暂不支持").foregroundStyle(.secondary)
                    if busy { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button(failures.isEmpty ? "全部提取并去重" : "重试未完成项", systemImage: "key.horizontal.fill") { extractAll() }
                        .buttonStyle(.borderedProminent).disabled(busy || testing || !validConnection)
                    if batchRunning {
                        Button(stopRequested ? "将在当前项结束后停止" : "完成当前项后停止") { stopRequested = true }.disabled(stopRequested)
                    }
                }
                if !failures.isEmpty { Text("未完成项可单独重试。").font(.caption).foregroundStyle(.secondary) }
                if batchRunning { ProgressView(value: Double(batchProgress), total: Double(max(batchTotal, 1))) }
                TextField("搜索 App、Bundle ID 或许可证 user / key", text: $search)
                if !installed.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(InstalledCredentialGroup.make(filteredInstalled).filter { $0.credentialID != nil }) { group in
                                if let credentialID = group.credentialID {
                                    DisclosureGroup {
                                        ForEach(group.members) { licenseRow($0) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Button {
                                                selectedCredentialID = credentialID; output = nil
                                            } label: {
                                                Label(credentialName(credentialID), systemImage: selectedCredentialID == credentialID ? "largecircle.fill.circle" : "circle").font(.headline)
                                            }.buttonStyle(.plain).disabled(busy || testing)
                                            Text("已验证可用于 \(group.members.count) 条许可证，无需重复提取").font(.caption).foregroundStyle(.secondary)
                                            Text(groupAccountDescription(group)).font(.caption).foregroundStyle(.secondary)
                                            Text(Array(Set(group.members.map(\.appName))).sorted().joined(separator: "、")).font(.caption).lineLimit(2)
                                        }.padding(.vertical, 10)
                                    }
                                } else {
                                    licenseRow(group.members[0])
                                }
                                Divider()
                            }
                            if filteredInstalled.contains(where: { $0.credentialMatch == nil }) {
                                DisclosureGroup("未确认来源（不计入已确认凭据数量）") {
                                    ForEach(filteredInstalled.filter { $0.credentialMatch == nil }) { licenseRow($0) }
                                }
                            }
                        }
                    }.frame(height: 300)
                } else {
                    Text(installed.isEmpty ? "尚未扫描设备许可证。" : "未找到匹配项，请修改搜索词。").foregroundStyle(.secondary)
                }
                if let record = selectedCredential {
                    HStack {
                        Text("已保存：" + record.displayName)
                        Button("查看凭据") { viewCredential(record.id) }.disabled(busy || testing)
                        Button("选择 IPA 解密", action: useCredentials).disabled(busy || testing)
                        Button("导出 credential.bin…") { exportData(record.data) }
                        Button("复制十六进制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.hex, forType: .string) }
                    }
                }
                if !failures.isEmpty {
                    DisclosureGroup("未完成 \(failures.count) 项（可重试）") {
                        ForEach(installed.filter { failures[$0.id] != nil }) { item in
                            Text(item.appName + "：" + (failures[item.id] ?? "")).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if let item = selectedInstalled {
                    Button("重新提取所选来源", systemImage: "key.fill") { extract() }
                        .buttonStyle(.borderedProminent).disabled(busy || testing || scannedSignature != signature)
                    Text("已选择：" + item.appName + " · user " + item.user + " / key " + item.key).textSelection(.enabled)
                    Text(recommended(item) && targetJob != nil ? "校验目标 IPA 成功后，保存至其下载账户。" : "未确认下载账户，结果保存为未绑定。").font(.caption).foregroundStyle(.secondary)
                }
                if let status { Label(status, systemImage: succeeded ? "checkmark.circle.fill" : "info.circle").foregroundStyle(succeeded ? Color.green : .secondary).textSelection(.enabled) }
                if !confirmedGroups.isEmpty && selectedCredential == nil {
                    Button("选择 IPA 解密", systemImage: "lock.open", action: useCredentials).disabled(busy || testing)
                }
                if let output { HStack { Button("导出 credential.bin…") { export(output) }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) } } }
            }
        }.formStyle(.grouped).onDisappear { if let snapshotFolder, !busy { try? FileManager.default.removeItem(at: snapshotFolder) }; revealPassword = false; revealRootPassword = false; if !busy && !testing { password = ""; rootPassword = "" } }.disabled(model.action != nil && !busy && !testing).task { if devices.isEmpty { discover() }; if license == nil { owner = model.activeProfile(beta: false)?.owner ?? model.activeProfile(beta: true)?.owner; selectAccountTarget() } }
        .onChange(of: signature) { installed = []; selectedLicenseID = nil; selectedCredentialID = nil; failures = [:]; scannedSignature = nil; output = nil; status = nil }
        .onChange(of: owner) { selectAccountTarget() }
        .onChange(of: targetJob) { if let job = accountJobs.first(where: { $0.id == targetJob }), let url = model.artifact(job, clear: false) { externalSource = false; inspect(url) } else if !externalSource { resetTarget() } }
    }
    private var confirmedGroups: [InstalledCredentialGroup] { InstalledCredentialGroup.make(installed).filter { $0.credentialID != nil } }
    private var pendingSupported: [InstalledLicense] { installed.filter { $0.supported && $0.credentialMatch == nil } }
    private var unsupportedCount: Int { installed.filter { !$0.supported && $0.credentialMatch == nil }.count }
    private var selectedCredential: FairPlayCredential? { model.credentials.first { $0.id.uuidString == selectedCredentialID } }
    private var accountJobs: [LocalJob] {
        guard let owner else { return [] }
        return model.jobs.filter { $0.credentialOwner == owner && ($0.flow == .store || $0.flow == .beta) && model.artifact($0, clear: false) != nil }
    }
    @ViewBuilder private func licenseRow(_ item: InstalledLicense) -> some View {
        Button {
            selectedLicenseID = item.id; output = nil; status = nil; succeeded = false
        } label: {
            HStack(alignment: .top) {
                Image(systemName: selectedLicenseID == item.id ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.appName).font(.headline)
                    Text(item.bundleID).font(.caption)
                    if let accounts = item.downloadAccounts, !accounts.isEmpty { Text("下载记录及许可证校验匹配：" + accounts.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                    else if let hint = item.metadataAccount { Text("设备元数据账户（未核验）：" + hint).font(.caption).foregroundStyle(.secondary) }
                    else { Text("下载 Apple ID 未知").font(.caption).foregroundStyle(.secondary) }
                    Text("user " + item.user + " / key " + item.key).font(.caption.monospaced())
                    Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    if item.credentialMatch == nil { Text("凭据尚未识别").font(.caption).foregroundStyle(.secondary) }
                    if recommended(item) { Label("匹配目标 IPA", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green) }
                    if !item.supported { Text(item.reason).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedLicenseID == item.id ? Color.accentColor.opacity(0.1) : Color.clear).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!item.supported || busy || testing)
    }
    private func groupAccountDescription(_ group: InstalledCredentialGroup) -> String {
        let accounts = Array(Set(group.members.flatMap { $0.downloadAccounts ?? [] })).sorted()
        if !accounts.isEmpty { return "下载记录及许可证校验匹配：" + accounts.joined(separator: "、") }
        let hints = Array(Set(group.members.compactMap(\.metadataAccount))).sorted()
        return hints.isEmpty ? "下载 Apple ID 未知" : "设备元数据账户（未核验）：" + hints.joined(separator: "、")
    }
    private func credentialName(_ id: String) -> String {
        model.credentials.first { $0.id.uuidString == id }?.displayName ?? "已保存凭据"
    }
    private func scanLicenses(_ arguments: [String], secret: String, key: URL?, automatic: Bool, base: URL) async throws -> [InstalledLicense] {
        let cache = base.appendingPathComponent("probe-" + UUID().uuidString + ".json")
        var seen = Set<Data>()
        let probes = model.credentials.compactMap { credential -> CredentialProbe? in
            guard !credential.isEnrollment, seen.insert(credential.data).inserted else { return nil }
            return CredentialProbe(id: credential.id.uuidString, data: credential.data)
        }
        let data = try JSONEncoder().encode(probes)
        guard FileManager.default.createFile(atPath: cache.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw LabError("无法创建本机凭据比对文件。") }
        defer { try? FileManager.default.removeItem(at: cache) }
        if let old = snapshotFolder { try? FileManager.default.removeItem(at: old) }
        let snapshot = base.appendingPathComponent("licenses-" + UUID().uuidString)
        snapshotFolder = snapshot
        let reply = try await ExtractorProcess.execute([automatic ? "scan-auto" : "scan"] + arguments + ["--known-hosts", base.appendingPathComponent("known_hosts").path, "--credential-cache", cache.path, "--license-cache", snapshot.path], password: secret, privateKey: key, rootPassword: rootPassword)
        accountReferences = await loadAccountReferences()
        return await annotateAccounts(reply.installedLicenses ?? [])
    }
    private func loadAccountReferences() async -> [DownloadLicenseReference] {
        var references: [DownloadLicenseReference] = []
        for job in model.jobs where job.flow == .store || job.flow == .beta {
            guard let owner = job.credentialOwner, let ipa = model.artifact(job, clear: false),
                  let licenses = try? await ExtractorProcess.execute(["inspect", "--ipa", ipa.path]).licenses else { continue }
            references += licenses.map { DownloadLicenseReference(owner: owner, ipa: ipa, member: $0.member, user: $0.user) }
        }
        return references
    }
    private func verifiedAccounts(_ credential: Data, user: String) async -> [String] {
        let references = accountReferences.filter { $0.user == user }
        return await Task.detached(priority: .userInitiated) {
            Array(Set(references.filter { FairPlay.credentialMatchesIPA(credential, source: $0.ipa, member: $0.member) }.map(\.owner))).sorted()
        }.value
    }
    private func annotateAccounts(_ licenses: [InstalledLicense]) async -> [InstalledLicense] {
        var result = licenses
        var cache: [String: [String]] = [:]
        for index in result.indices {
            guard let match = result[index].credentialMatch, let credential = model.credentials.first(where: { $0.id.uuidString == match }) else { continue }
            let key = match + ":" + result[index].user
            let accounts: [String]
            if let existing = cache[key] { accounts = existing }
            else { accounts = await verifiedAccounts(credential.data, user: result[index].user); cache[key] = accounts }
            result[index].downloadAccounts = accounts
        }
        return result
    }
    private var selectedInstalled: InstalledLicense? { installed.first { $0.id == selectedLicenseID && $0.supported } }
    private var filteredInstalled: [InstalledLicense] {
        installed.filter { search.isEmpty || [$0.appName, $0.bundleID, $0.user, $0.key].joined(separator: " ").localizedCaseInsensitiveContains(search) }
    }
    private func recommended(_ item: InstalledLicense) -> Bool {
        validTarget && choices.first(where: { $0.member == member })?.user == item.user
    }
    private var validTarget: Bool { !inspecting && license != nil && choices.contains(where: { $0.member == member }) }
    private func resetTarget() {
        inspectionID = UUID(); choices = []; member = ""; license = nil; inspecting = false; status = nil; output = nil; succeeded = false
    }
    private func selectAccountTarget() {
        externalSource = false; selectedLicenseID = nil; resetTarget()
        targetJob = accountJobs.first?.id
        if let job = accountJobs.first, let url = model.artifact(job, clear: false) { inspect(url) }
    }
    private func inspect(_ url: URL) {
        let request = UUID(); inspectionID = request; inspecting = true; license = url; choices = []; member = ""; status = nil; output = nil; succeeded = false
        Task {
            do {
                let result = try await ExtractorProcess.execute(["inspect", "--ipa", url.path])
                guard inspectionID == request else { return }
                choices = result.licenses ?? []; member = choices.first?.member ?? ""; inspecting = false
            } catch {
                guard inspectionID == request else { return }
                inspecting = false; status = model.friendly(error)
            }
        }
    }
    private func choose(ipa: Bool = false) -> URL? {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if ipa { panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data] }
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func discover() {
        discovering = true
        Task { defer { discovering = false }; do { devices = try await ExtractorProcess.execute(["devices"]).devices ?? []; if devices.count == 1 { selected = devices[0].id } else if !devices.contains(where: { $0.id == selected }) { selected = "" }; status = devices.isEmpty ? "请连接、解锁设备，并在设备上信任这台 Mac。" : nil } catch { status = model.friendly(error) } }
    }
    private var validConnection: Bool {
        Int(port).map { (1...65535).contains($0) } == true && (mode == "usb" ? !selected.isEmpty : !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var signature: String { [mode, selected, host, port, username, elevation, String(rootPassword.hashValue), privateKey?.path ?? "", String(password.hashValue), String(automaticAuthentication)].joined(separator: "|") }
    private func captureDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IPADecryptMac/DeviceCaptures")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base
    }
    private func connectionArguments() -> [String] {
        var args = ["--remote-port", port, "--user", username.trimmingCharacters(in: .whitespacesAndNewlines), "--elevation", elevation]
        if mode == "usb" { args += ["--device", selected] }
        else { args += ["--host", host.trimmingCharacters(in: .whitespacesAndNewlines)] }
        return args
    }
    private func testConnection() {
        guard validConnection, !testing, !busy else { return }
        let settings = signature, arguments = connectionArguments(), secret = password, key = privateKey, automatic = automaticAuthentication
        testing = true; tested = nil; succeeded = false; status = "正在测试 SSH 连接与 root 身份…"
        model.action = "正在测试设备连接"
        Task {
            defer { testing = false; model.action = nil }
            do {
                let base = try captureDirectory()
                let reply = try await ExtractorProcess.execute([automatic ? "test-auto" : "test"] + arguments + ["--known-hosts", base.appendingPathComponent("known_hosts").path], password: secret, privateKey: key, rootPassword: rootPassword)
                tested = settings; succeeded = true; status = reply.message ?? "SSH 连接成功，root 身份已确认。"
            } catch { status = model.friendly(error) }
        }
    }
    private func scan() {
        guard !busy, !testing, validConnection else { return }
        let settings = signature, arguments = connectionArguments(), secret = password, key = privateKey, automatic = automaticAuthentication
        busy = true; model.action = "正在扫描设备许可证"; installed = []; selectedLicenseID = nil; scannedSignature = nil; output = nil; succeeded = false; status = "正在读取已安装 App 的许可证…"
        Task {
            defer { busy = false; model.action = nil }
            do {
                let base = try captureDirectory()
                installed = try await scanLicenses(arguments, secret: secret, key: key, automatic: automatic, base: base); scannedSignature = settings
                status = installed.isEmpty ? "没有找到设备许可证。请确认目标 App 已从 App Store 安装。" : "扫描完成，相同凭据的来源已合并。展开来源可重新提取；未识别项可选择提取。"
            } catch { status = model.friendly(error) }
        }
    }
    private func extract() {
        guard !busy, !testing, validConnection, scannedSignature == signature, let deviceLicense = selectedInstalled else { return }
        let automatic = automaticAuthentication
        let targetChoice = recommended(deviceLicense) ? choices.first(where: { $0.member == member }) : nil
        let ipa = targetChoice == nil ? nil : license
        let account = ipa.flatMap { ipa in accountJobs.first(where: { $0.id == targetJob && model.artifact($0, clear: false) == ipa })?.credentialOwner }
        busy = true; model.action = "正在提取所选许可证"; succeeded = false; output = nil; status = "正在提取：" + deviceLicense.appName
        let arguments = connectionArguments(), secret = password, key = privateKey
        Task {
            defer { busy = false; model.action = nil }
            do {
                let base = try captureDirectory()
                let target = base.appendingPathComponent(UUID().uuidString)
                var args = [automatic ? "auto" : "extract"] + arguments + ["--output", target.path, "--known-hosts", base.appendingPathComponent("known_hosts").path]
                args += ["--installed-sinf", deviceLicense.path, "--expected-sinf-hash", deviceLicense.digest]
                if let ipa, let targetChoice { args += ["--ipa", ipa.path, "--sinf-member", targetChoice.member] }
                let reply = try await ExtractorProcess.execute(args, password: secret, privateKey: key, rootPassword: rootPassword)
                guard let path = reply.path else { throw LabError("未收到提取结果。") }
                let file = URL(fileURLWithPath: path)
                guard AppFileLibrary.contains(file, root: target) else { throw LabError("提取器返回了无效路径。") }
                guard let evidence = reply.selection, evidence.user == (targetChoice?.user ?? deviceLicense.user), evidence.key == (targetChoice?.key ?? deviceLicense.key), evidence.triggerUser == deviceLicense.user, evidence.triggerKey == deviceLicense.key, evidence.installedPath == deviceLicense.path, evidence.installedDigest == deviceLicense.digest else { throw LabError("提取结果未匹配目标许可证，未导入。") }
                let data = try CredentialFileReader.read(file)
                try model.addCredential(data, owner: account, origin: "越狱设备提取 · " + (mode == "usb" ? "USB" : "网络"), evidence: evidence)
                status = "提取完成，正在用新凭据比对并合并其他许可证…"
                do { installed = try await scanLicenses(arguments, secret: secret, key: key, automatic: automatic, base: base) }
                catch { status = "凭据已保存，列表比对未完成，可重新扫描。"; output = file; succeeded = true; return }
                revealPassword = false; output = file; succeeded = true; status = "已验证所选许可证；触发 App：" + evidence.appName + "。" + (account == nil ? "已保存为未绑定凭据。" : "已保存至目标下载账户。")
            } catch { status = model.friendly(error) }
        }
    }
    private func exportData(_ data: Data) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "credential.bin"
        if panel.runModal() == .OK, let destination = panel.url {
            do { try data.write(to: destination, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path) }
            catch { status = "导出失败，请检查目标位置。" }
        }
    }
    private func matchSnapshots(_ licenses: [InstalledLicense], folder: URL) async throws -> [InstalledLicense] {
        let credentials = model.credentials.filter { !$0.isEnrollment }
        return try await Task.detached(priority: .userInitiated) {
            try licenses.map { item in
                var result = item
                guard item.digest.count == 64, item.digest.allSatisfy({ $0.isHexDigit }) else { return result }
                let path = folder.appendingPathComponent(item.digest + ".sinf")
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576,
                      let data = try? Data(contentsOf: path),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.digest else {
                    if item.supported { throw LabError("许可证快照缺失或已变化，请重新扫描。") }; return result
                }
                result.credentialMatch = credentials.first { FairPlay.credentialMatches($0.data, license: data) }?.id.uuidString
                return result
            }
        }.value
    }
    private func extractOne(_ item: InstalledLicense, arguments: [String], secret: String, key: URL?, automatic: Bool, base: URL) async throws {
        let target = base.appendingPathComponent(UUID().uuidString)
        let args = [automatic ? "auto" : "extract"] + arguments + ["--output", target.path, "--known-hosts", base.appendingPathComponent("known_hosts").path, "--installed-sinf", item.path, "--expected-sinf-hash", item.digest]
        let reply = try await ExtractorProcess.execute(args, password: secret, privateKey: key, rootPassword: rootPassword)
        guard let path = reply.path, let evidence = reply.selection,
              evidence.user == item.user, evidence.key == item.key, evidence.triggerUser == item.user,
              evidence.triggerKey == item.key, evidence.installedPath == item.path, evidence.installedDigest == item.digest else { throw LabError("返回结果与所选许可证不符。") }
        let file = URL(fileURLWithPath: path)
        guard AppFileLibrary.contains(file, root: target) else { throw LabError("提取器返回无效路径。") }
        let data = try CredentialFileReader.read(file)
        let accounts = await verifiedAccounts(data, user: item.user)
        let existing = model.credentials.first { $0.data == data }
        let account: String?
        if let existing { account = existing.owner }
        else { account = accounts.count == 1 ? accounts.first : nil }
        try model.addCredential(data, owner: account, origin: "设备批量提取", evidence: evidence)
        output = file
    }
    private func extractAll() {
        guard !busy, !testing, validConnection else { return }
        let settings = signature, arguments = connectionArguments(), secret = password, key = privateKey, automatic = automaticAuthentication
        busy = true; batchRunning = true; stopRequested = false; failures = [:]; output = nil; selectedCredentialID = nil; succeeded = false
        model.action = "正在全部提取并去重"; status = "正在扫描设备许可证…"
        Task {
            defer { busy = false; batchRunning = false; model.action = nil; revealPassword = false }
            do {
                let base = try captureDirectory()
                installed = try await scanLicenses(arguments, secret: secret, key: key, automatic: automatic, base: base)
                scannedSignature = settings; selectedLicenseID = nil
                guard let folder = snapshotFolder else { throw LabError("缺少本机许可证快照。") }
                batchTotal = installed.filter(\.supported).count; batchProgress = installed.filter { $0.supported && $0.credentialMatch != nil }.count
                var plan = CredentialBatchPlan()
                while !stopRequested, let item = plan.next(in: installed) {
                    plan.attempted.insert(item.id)
                    status = "正在提取 " + item.appName + " · 已确认 \(confirmedGroups.count) 个不同凭据"
                    do {
                        try await extractOne(item, arguments: arguments, secret: secret, key: key, automatic: automatic, base: base)
                        installed = await annotateAccounts(try await matchSnapshots(installed, folder: folder))
                    } catch { plan.failures[item.id] = model.friendly(error) }
                    plan.reconcile(installed); failures = plan.failures
                    batchProgress = installed.filter { $0.supported && ($0.credentialMatch != nil || plan.attempted.contains($0.id)) }.count
                }
                succeeded = pendingSupported.isEmpty
                status = (stopRequested ? "已停止，保留已确认结果。" : "批量处理结束。") + "已确认 \(confirmedGroups.count) 个不同凭据；未完成 \(pendingSupported.count) 条，暂不支持 \(unsupportedCount) 条。" + (confirmedGroups.isEmpty ? "本次未保存凭据。" : "凭据已保存，可在处理记录中用于解密。")
            } catch { status = model.friendly(error) }
        }
    }
    private func export(_ file: URL) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "credential.bin"
        if panel.runModal() == .OK, let destination = panel.url { do { try Data(contentsOf: file).write(to: destination, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path) } catch { status = "导出失败，请检查目标位置。" } }
    }
}

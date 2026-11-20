import AppKit
import AppleAuth
import SwiftUI
import UniformTypeIdentifiers

@main struct IPADecryptMac: App {
    @StateObject private var model = LocalLab()
    var body: some Scene {
        WindowGroup("IPA 解密") {
            MacWorkspace(model: model).frame(minWidth: 980, minHeight: 660)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--native-runtime-check") {
                        do {
                            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            defer { try? FileManager.default.removeItem(at: folder) }
                            let runtime = try NativeStoreLogin(directory: folder)
                            defer { runtime.close() }
                            let passed = try await runtime.runtimeCheck(sign: true)
                            print("mac-native-runtime-check: \(passed ? "passed" : "failed")"); fflush(stdout)
                        } catch { print("mac-native-runtime-check: failed \(error.localizedDescription)"); fflush(stdout) }
                    }
                }
        }.defaultSize(width: 1180, height: 790)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入 IPA…") { NotificationCenter.default.post(name: .init("ImportIPA"), object: nil) }.keyboardShortcut("o")
            }
        }
    }
}

enum MacPage: String, CaseIterable, Identifiable {
    case store = "App Store", beta = "TestFlight", history = "处理记录", credentials = "FairPlay 凭据", device = "越狱设备提取"
    var id: String { rawValue }
    var icon: String {
        switch self { case .store: return "square.stack"; case .beta: return "paperplane"; case .history: return "clock"; case .credentials: return "key"; case .device: return "iphone.and.arrow.forward" }
    }
}
struct PendingStoreRequest {
    enum Kind { case latest, versions, acquire }
    let app: AppResult
    let kind: Kind
    var replacing: LocalJob? = nil
    var version: String? = nil
}
struct VersionSelection: Identifiable { let app: AppResult; let versions: StoreVersionList; var id: UInt64 { app.id } }

@MainActor struct MacWorkspace: View {
    @ObservedObject var model: LocalLab
    @State private var page: MacPage? = .store
    @State private var query = ""
    @State private var results: [AppResult] = []
    @State private var searched = false
    @State private var detail: AppSelection?
    private enum DetailAction { case download(AppResult), versions(AppResult), acquire(AppResult) }
    @State private var detailAction: DetailAction?
    @State private var tests: [Beta] = []
    @State private var login = false
    @State private var loginBeta = false
    @State private var version: VersionSelection?
    @State private var webFile: URL?
    @State private var webURL: URL?
    @State private var server: LANShareServer?
    @State private var removing: LocalJob?
    @State private var pendingStoreRequest: PendingStoreRequest?
    @State private var incomingCredential: URL?

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("获取与处理") {
                    ForEach([MacPage.store, .beta, .history]) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }
                Section("账户与设备") {
                    ForEach([MacPage.credentials, .device]) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }
                Section {
                    Button("导入本地 IPA…", systemImage: "square.and.arrow.down") { importIPA() }.buttonStyle(.plain)
                }
            }.disabled(deviceBusy).listStyle(.sidebar).navigationTitle("IPA 解密")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Mac 独立版", systemImage: "desktopcomputer").font(.headline)
                    Text("下载 · 解密 · 设备凭据").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 260)
        } detail: {
            Group {
                switch page ?? .store {
                case .store: storeView
                case .beta: betaView
                case .history: historyView
                case .credentials: MacCredentials(model: model, incomingFile: $incomingCredential)
                case .device: CredentialExtractionView(model: model)
                }
            }.navigationTitle((page ?? .store).rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let action = model.action { HStack { ProgressView().controlSize(.small); Text(model.automaticStoreLoginStatus ?? action).font(.caption) } }
                }
                ToolbarItem {
                    Button("Apple 账户", systemImage: "person.crop.circle") { loginBeta = page == .beta; login = true }.disabled(model.action != nil)
                }
            }
        }
        .sheet(item: $detail, onDismiss: continueDetailAction) { selected in
            NavigationStack {
                AppDetailView(model: model, selection: selected,
                    onDownload: { detailAction = .download($0); detail = nil },
                    onVersions: { detailAction = .versions($0); detail = nil },
                    onAcquire: { detailAction = .acquire($0); detail = nil })
                    .toolbar { ToolbarItem { Button("关闭") { detail = nil } } }
            }.frame(width: 860, height: 760)
        }
        .sheet(isPresented: $login, onDismiss: resumeStoreRequest) { MacAccounts(model: model, beta: loginBeta) }
        .onChange(of: model.storeConnected) { if model.storeConnected && pendingStoreRequest != nil && login { login = false } }
        .sheet(isPresented: Binding(get: { model.askingCode && !login && version == nil && detail == nil }, set: { if !$0 { model.finishCode(nil) } }), onDismiss: { model.finishCode(nil) }) {
            MacVerification(model: model)
        }
        .sheet(item: $version) { selection in
            MacVersionPicker(model: model, selection: selection) { value in
                version = nil; download(selection.app, version: value)
            }
            .sheet(isPresented: Binding(get: { model.askingCode }, set: { if !$0 { model.finishCode(nil) } }),
                   onDismiss: { model.finishCode(nil) }) { MacVerification(model: model) }
        }
        .sheet(isPresented: Binding(get: { webFile != nil }, set: { if !$0 { stopWeb() } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("网页下载").font(.title2.bold())
                Text(webFile?.lastPathComponent ?? "").foregroundStyle(.secondary)
                if let webURL { Text(webURL.absoluteString).textSelection(.enabled).font(.body.monospaced()); Button("复制地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(webURL.absoluteString, forType: .string) } }
                else { ProgressView("正在开启局域网分享…") }
                Text("同一局域网的设备可下载此文件；关闭窗口即停止分享。").font(.caption).foregroundStyle(.secondary)
                Button("停止分享") { stopWeb() }.keyboardShortcut(.cancelAction)
            }.padding(28).frame(width: 540)
        }
        .alert("操作提示", isPresented: Binding(get: { model.message != nil && !login }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("删除记录及其 IPA 文件？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("删除", role: .destructive) { if let removing { do { try model.removeJob(removing) } catch { model.message = model.friendly(error) } }; removing = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ImportIPA"))) { _ in importIPA() }
        .onChange(of: model.accounts.activeBeta) { tests = [] }
        .onChange(of: model.accounts.activeStore) { results = []; searched = false }
        .onChange(of: model.country) { results = []; searched = false }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "ipa" { run("正在导入 IPA") { try await model.importIPA(url) }; page = .history }
            else if url.pathExtension.lowercased() == "bin" { incomingCredential = url; page = .credentials }
        }
    }
    private var storeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("名称、App ID、Bundle ID 或商店链接", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("搜索", action: search).keyboardShortcut(.return, modifiers: []).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || model.action != nil)
                Menu {
                    Button("自动 · " + Storefronts.name(model.automaticCountry)) { model.region = "" }
                    Divider()
                    ForEach(Storefronts.regions, id: \.self) { country in
                        Button(Storefronts.name(country)) { model.region = country }
                    }
                } label: { Label(Storefronts.name(model.country), systemImage: "globe") }
                .disabled(model.action != nil)
            }.padding()
            Divider()
            if !model.storeConnected {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.storeNeedsReauth ? (model.canAttemptStoreOperation ? "App Store 会话已过期，将在下次操作时自动重新登录。" : "App Store 会话已失效，需要重新登录后下载。") : "搜索无需登录；下载 IPA 需要先登录 App Store 账户。")
                        if let pendingStoreRequest { Text("登录后继续：" + pendingStoreRequest.app.trackName).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(model.storeNeedsReauth ? "重新登录" : "登录 App Store") { loginBeta = false; login = true }.disabled(model.action != nil)
                }.padding().background(Color.orange.opacity(0.08))
            }
            if model.action == "正在搜索" { Spacer(); ProgressView("正在搜索 App Store…"); Spacer() }
            else if results.isEmpty { ContentUnavailableView(searched ? "未找到应用" : "查找 App Store 应用", systemImage: "magnifyingglass", description: Text(searched ? "请尝试其他名称、应用链接或商店地区。" : "输入应用名称、App ID、Bundle ID 或 App Store 链接。")) }
            else {
                List(results) { app in
                    HStack(spacing: 14) {
                        Button { detail = AppSelection(app: app, country: model.country) } label: { AppListingLabel(app: app) }
                            .buttonStyle(.plain).accessibilityLabel("查看详情，\(app.trackName)")
                        Button("详情") { detail = AppSelection(app: app, country: model.country) }
                        Menu("下载") {
                            Button("最新版本") { requestStore(app, kind: .latest) }
                            Button("选择历史版本…") { requestStore(app, kind: .versions) }
                            if app.price == 0 { Button("获取免费授权") { requestStore(app, kind: .acquire) } }
                        }.disabled(model.action != nil)
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private var betaView: some View {
        VStack {
            HStack { Text("已加入的测试").font(.title2.bold()); Spacer(); Button("刷新", systemImage: "arrow.clockwise") { loadTests() }.disabled(!model.betaConnected || model.action != nil) }.padding()
            if tests.isEmpty { ContentUnavailableView("TestFlight", systemImage: "paperplane", description: Text(model.betaConnected ? "点击刷新读取测试目录。" : "先登录 TestFlight 账户。")) }
            else { List(tests) { app in HStack { VStack(alignment: .leading, spacing: 4) { Text(app.name).font(.headline); Text(app.id).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("下载 IPA") { page = .history; run("正在下载测试版") { try await model.downloadBeta(app.name, bundle: app.id) } }.disabled(model.action != nil) }.padding(.vertical, 8) } }
        }.task { if tests.isEmpty && model.betaConnected { loadTests() } }
    }
    private var historyView: some View {
        Group {
            if model.jobs.isEmpty { ContentUnavailableView("尚无处理记录", systemImage: "tray", description: Text("从商店下载或导入本地 IPA 后，进度与结果会显示在这里。")) }
            else { List(model.jobs) { job in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: job.state == .ready ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.circle" : "doc.zipper").foregroundStyle(job.state == .ready ? Color.green : .secondary); Text(job.name).font(.headline); Spacer(); Text(job.state.title).foregroundStyle(.secondary) }
                    Text(job.source + (job.version.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                    if let account = job.credentialOwner { Text("下载账户 · " + account).font(.caption).foregroundStyle(.secondary) }
                    if let progress = model.downloads[job.id] {
                        ProgressView(value: progress.fraction)
                        Text(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file) + (progress.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file) : "")).font(.caption.monospacedDigit())
                    }
                    if let note = job.note { Text(note).font(.callout).foregroundStyle(job.state == .failed ? .red : .secondary).textSelection(.enabled) }
                    HStack {
                        if let original = model.artifact(job, clear: false) {
                            Button("导出原始包") { export(original) }
                            Button(job.state == .failed ? "重试解密" : "解密") { run("正在解密 IPA") { try await model.decrypt(job) } }.disabled(model.action != nil || !model.hasCredentials(for: job))
                        }
                        if let decrypted = model.artifact(job, clear: true) {
                            Button("导出解密版") { export(decrypted) }; Button("网页下载") { share(decrypted) }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([decrypted]) }
                        }
                        if job.state == .failed, model.artifact(job, clear: false) == nil, let app = job.storeApp {
                            Button("重新下载") { requestStore(app, kind: .latest, replacing: job, version: job.version) }
                            if job.needsStoreLicense && app.price == 0 {
                                Button("获取免费授权并重试") { requestStore(app, kind: .acquire, replacing: job) }
                            }
                        }
                        if job.state == .failed, model.artifact(job, clear: false) == nil, let bundle = job.retryBetaBundle {
                            Button("重新下载") {
                                if model.betaConnected { run("正在重新下载测试版") { try await model.downloadBeta(job.name, bundle: bundle, replacing: job) } }
                                else { loginBeta = true; login = true }
                            }
                        }
                        if job.state == .failed {
                            Button("管理凭据") { page = .credentials }
                            if job.flow == .store || job.flow == .beta {
                                Button("账户设置") { loginBeta = job.flow == .beta; login = true }
                            }
                        }
                        Spacer(); Button("删除", role: .destructive) { removing = job }.disabled(model.action != nil)
                    }.controlSize(.small).disabled(model.action != nil)
                }.padding(.vertical, 10)
            } }
        }
    }
    private var deviceBusy: Bool {
        guard let action = model.action else { return false }
        return ["正在提取设备凭据", "正在测试设备连接", "正在扫描设备许可证", "正在提取所选许可证", "正在全部提取并去重"].contains(action)
    }
    private func continueDetailAction() {
        guard let action = detailAction else { return }
        detailAction = nil
        switch action {
        case .download(let app): requestStore(app, kind: .latest)
        case .versions(let app): requestStore(app, kind: .versions)
        case .acquire(let app): requestStore(app, kind: .acquire)
        }
    }
    private func requestStore(_ app: AppResult, kind: PendingStoreRequest.Kind, replacing: LocalJob? = nil, version: String? = nil) {
        let request = PendingStoreRequest(app: app, kind: kind, replacing: replacing, version: version)
        guard model.canAttemptStoreOperation else { pendingStoreRequest = request; loginBeta = false; login = true; return }
        performStoreRequest(request)
    }
    private func resumeStoreRequest() {
        guard let request = pendingStoreRequest else { return }
        pendingStoreRequest = nil
        if model.storeConnected { performStoreRequest(request) }
    }
    private func performStoreRequest(_ request: PendingStoreRequest) {
        switch request.kind {
        case .latest: page = .history; run("正在下载 IPA") { try await model.download(request.app, version: request.version, replacing: request.replacing) }
        case .versions: run("正在读取版本") { let versions = try await model.versions(for: request.app); version = VersionSelection(app: request.app, versions: versions) }
        case .acquire: run("正在请求授权") {
            try await model.acquire(request.app)
            if let job = request.replacing { try await model.download(request.app, version: job.version, replacing: job) }
        }
        }
    }
    private func search() { run("正在搜索") { results = []; searched = false; results = try await model.catalog(query); searched = true } }
    private func loadTests() { run("正在读取测试目录") { tests = try await model.betaCatalog() } }
    private func download(_ app: AppResult, version: String? = nil) { page = .history; run("正在下载 IPA") { try await model.download(app, version: version) } }
    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard model.action == nil else { return }; model.action = title
        Task { defer { model.action = nil }; do { try await operation() } catch { model.message = model.friendly(error) } }
    }
    private func importIPA() {
        guard model.action == nil else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { page = .history; run("正在导入 IPA") { try await model.importIPA(url) } }
    }
    private func export(_ url: URL) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let destination = panel.url {
            do { let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() } }; try Data(contentsOf: url, options: .mappedIfSafe).write(to: destination, options: .atomic) }
            catch { model.message = "无法导出文件，请检查目标位置和剩余存储。" }
        }
    }
    private func share(_ url: URL) {
        do { let share = try LANShareServer(file: url); server = share; webFile = url; share.start { result in DispatchQueue.main.async { switch result { case .success(let value): webURL = value; case .failure(let error): model.message = error.localizedDescription; stopWeb() } } } }
        catch { model.message = error.localizedDescription }
    }
    private func stopWeb() { server?.stop(); server = nil; webFile = nil; webURL = nil }
}

@MainActor struct MacAccounts: View {
    @ObservedObject var model: LocalLab
    @Environment(\.dismiss) private var dismiss
    @State var beta: Bool
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var reveal = false
    @State private var remember = false
    @State private var native = true
    @State private var sms = false
    @State private var busy = false
    @State private var problem: String?
    @State private var diagnostic: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Apple 账户").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(busy) }
            Picker("服务", selection: $beta) { Text("App Store").tag(false); Text("TestFlight").tag(true) }.pickerStyle(.segmented).disabled(busy)
            ScrollView {
                Form {
                    Section("已保存账户") {
                        ForEach(beta ? model.accounts.beta : model.accounts.store) { account in
                            HStack { Button(account.email) { do { try model.switchAccount(account.id, beta: beta); email = account.email; password = model.savedPassword(for: email) ?? "" } catch { problem = model.friendly(error) } }; if !beta && account.needsReauth == true { Text("需重新登录").font(.caption).foregroundStyle(.orange) }; Spacer(); if model.activeProfile(beta: beta)?.id == account.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) } }
                        }
                        Button("退出当前账户") { do { try model.signOut(beta: beta) } catch { problem = model.friendly(error) } }
                    }.disabled(busy)
                    Section("登录或添加账户") {
                        if !beta && model.storeNeedsReauth { Text("当前 App Store 会话已失效。请选择账户并重新登录；仅切换账户不会刷新过期会话。").font(.caption).foregroundStyle(.orange) }
                        TextField("Apple 账户", text: $email).textContentType(.username)
                        HStack { Group { if reveal { TextField("密码", text: $password) } else { SecureField("密码", text: $password) } }; Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless) }
                        Toggle("在此 Mac 保存密码", isOn: $remember)
                        if !beta {
                            Toggle("会话过期后自动重新登录", isOn: $model.automaticStoreLogin)
                            Text("仅使用此 Mac 已保存的密码；Apple 要求验证码时仍需输入。自动恢复失败后停止，手动登录成功或更新保存密码后可再次自动恢复。").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("填入已保存密码") { password = model.savedPassword(for: email) ?? "" }
                        if beta { Toggle("设备验证登录", isOn: $native); if !native { Toggle("使用短信验证码", isOn: $sms) } }
                        TextField("已有验证码（可留空）", text: $code).textContentType(.oneTimeCode)
                        Button(busy ? "正在登录…" : "登录") { signIn() }.buttonStyle(.borderedProminent).disabled(busy || email.isEmpty || password.isEmpty)
                        if beta { Button("重建 TestFlight 会话") { busy = true; Task { defer { busy = false }; do { try await model.retryBetaSession(email: email); problem = "会话已建立。" } catch { show(error) } } }.disabled(busy || email.isEmpty) }
                    }
                    Section("搜索地区") {
                        Picker("地区", selection: $model.region) { Text("自动 · " + Storefronts.name(model.automaticCountry)).tag(""); ForEach(Storefronts.regions, id: \.self) { Text(Storefronts.name($0)).tag($0) } }
                    }
                    if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                    if let diagnostic { Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled) }
                }.formStyle(.grouped)
            }
        }.padding(24).frame(width: 560, height: 680)
        .sheet(isPresented: $model.askingCode, onDismiss: { model.finishCode(nil) }) { MacVerification(model: model) }
        .onAppear { if email.isEmpty { email = model.activeProfile(beta: beta)?.email ?? "" } }
        .onChange(of: beta) { email = model.activeProfile(beta: beta)?.email ?? ""; password = ""; code = ""; problem = nil; diagnostic = nil }
    }
    private func show(_ error: Error) { problem = model.friendly(error); diagnostic = (error as? StoreIssue)?.diagnostic }
    private func signIn() {
        let user = email, secret = password, service = beta, save = remember, useNative = native, initial = code, useSMS = sms
        busy = true; problem = nil; diagnostic = nil
        Task { defer { busy = false }; do { try await model.login(email: user, password: secret, beta: service, initialCode: initial, betaSMS: useSMS, nativeBeta: service && useNative); if save { try model.savePassword(secret, for: user) }; password = ""; code = ""; problem = "登录成功。" } catch { show(error) } }
    }
}

@MainActor struct MacVerification: View {
    @ObservedObject var model: LocalLab
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("双重认证").font(.title2.bold())
            if model.pickingBetaPhone {
                Text("选择短信接收号码")
                ForEach(Array(model.codePhones.enumerated()), id: \.element.id) { index, phone in Button(phone.displayNumber.isEmpty ? "受信任号码 \(index + 1)" : phone.displayNumber) { model.selectBetaPhone(phone.id) } }
                if model.betaCanUseTrustedDevice { Button("改用受信任设备") { model.selectBetaPhone(0) } }
            } else {
                TextField("6 位验证码", text: $code).textContentType(.oneTimeCode).textFieldStyle(.roundedBorder)
                Button("提交验证码") { model.finishCode(code) }.disabled(code.count != 6 || !code.allSatisfy { $0.isASCII && $0.isNumber }).keyboardShortcut(.defaultAction)
            }
            if model.storeCodeDelivery {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = max(0, Int(ceil(model.nextCodeRequest.timeIntervalSince(context.date))))
                    VStack(alignment: .leading, spacing: 10) {
                        Button("重新发送到受信任设备") { model.requestStoreCode(method: .trustedDevice) }
                        if model.codePhones.isEmpty { Button("选择受信任手机号") { model.requestStoreCode(method: .sms) } }
                        ForEach(model.codePhones, id: \.id) { phone in Button("发送短信到 " + phone.displayNumber) { model.requestStoreCode(method: .sms, phoneID: phone.id) } }
                        if wait > 0 { Text("\(wait) 秒后可重发").font(.caption) }
                    }.disabled(model.codeDeliveryBusy || wait > 0)
                }
                if let message = model.codeDeliveryMessage { Text(message).font(.caption) }
            }
            Button("取消") { model.finishCode(nil) }.keyboardShortcut(.cancelAction)
        }.padding(28).frame(width: 420)
    }
}

@MainActor struct MacVersionPicker: View {
    @ObservedObject var model: LocalLab
    let selection: VersionSelection
    let download: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var manual = ""
    @State private var query = ""
    @State private var names: [String: String] = [:]
    @State private var loading = false
    @State private var problem: String?
    private var ids: [String] { selection.versions.ids.filter { query.isEmpty || $0.contains(query) || (names[$0]?.localizedCaseInsensitiveContains(query) ?? false) } }
    private var target: String? {
        let value = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return selected.isEmpty ? nil : selected }
        return value.allSatisfy { $0.isASCII && $0.isNumber } ? value : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppListingLabel(app: selection.app)
            Text("历史版本").font(.title2.bold())
            TextField("筛选版本号或版本 ID", text: $query).textFieldStyle(.roundedBorder)
            List(ids, id: \.self) { id in
                Button { selected = id; manual = "" } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            if let name = names[id] { Text("版本 " + name).font(.headline) }
                            Text("版本 ID " + id).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if id == selection.versions.latest { Text("最新版").font(.caption).foregroundStyle(.secondary) }
                        if selected == id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.frame(minHeight: 200)
            TextField("或输入版本 ID", text: $manual).textFieldStyle(.roundedBorder)
            if !manual.isEmpty && target == nil { Text("版本 ID 只能包含数字。").font(.caption).foregroundStyle(.red) }
            if loading { ProgressView("正在读取版本号…") }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("读取版本号") { if let target { Task { await readName(target) } } }.disabled(target == nil || loading)
                Button("下载所选版本") { if let target { download(target) } }.disabled(target == nil || loading).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 560, height: 640)
        .task {
            if let latest = selection.versions.latest, let name = selection.app.version,
               Storefronts.country(for: model.activeProfile(beta: false)?.storefront) == model.country { names[latest] = name }
        }
        .task(id: selected) { if !selected.isEmpty && names[selected] == nil { await readName(selected) } }
    }
    private func readName(_ id: String) async {
        loading = true; problem = nil
        defer { loading = false }
        do {
            let name = try await model.versionName(id, for: selection.app)
            if !Task.isCancelled {
                if let name, !name.isEmpty { names[id] = name }
                else { problem = "此版本暂未提供版本号。" }
            }
        } catch { if !Task.isCancelled { problem = model.friendly(error) } }
    }
}

import SwiftUI
import UniformTypeIdentifiers

@main struct IPALab: App {
    #if DEBUG
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--testflight-catalog-check") {
            Task { @MainActor in
                let model = LocalLab()
                do {
                    let apps = try await model.betaCatalog()
                    print("testflight-catalog-check: count=\(apps.count)")
                } catch let issue as StoreIssue { print("testflight-catalog-check: \(issue.diagnostic ?? "failed")") }
                catch { print("testflight-catalog-check: failed") }
                fflush(stdout)
            }
        }
        if arguments.contains("--native-store-runtime-check") {
            Task { @MainActor in
                do {
                    let location = FileManager.default.temporaryDirectory.appendingPathComponent("native-store-check-" + UUID().uuidString)
                    let runtime = try NativeStoreLogin(directory: location)
                    defer { runtime.close(); try? FileManager.default.removeItem(at: location) }
                    print("native-store-runtime-check: starting")
                    fflush(stdout)
                    let ready = try await runtime.runtimeCheck(sign: true)
                    print("native-store-runtime-check: \(ready ? "passed" : "failed")")
                } catch let issue as StoreIssue { print("native-store-runtime-check: \(issue.diagnostic ?? "failed")") }
                catch { print("native-store-runtime-check: failed") }
                fflush(stdout)
            }
        }
        if let check = ["runtime-check", "provisioning-check"].first(where: { arguments.contains("--ipatool-\($0)") }) {
            DispatchQueue.global(qos: .utility).async {
                "{\"operation\":\"\(check)\"}".withCString { request in
                    guard let response = IPAToolCall(UnsafeMutablePointer(mutating: request)) else {
                        print("ipatool-\(check): no response")
                        return
                    }
                    defer { IPAToolFree(response) }
                    print("ipatool-\(check): \(String(cString: response))")
                    fflush(stdout)
                }
            }
        }
    }
    #endif
    var body: some Scene { WindowGroup { Workspace() } }
}

@MainActor private struct Workspace: View {
    @StateObject private var model = LocalLab()
    @State private var page = 0
    @State private var flow: Flow = .store
    @State private var query = ""
    @State private var beta = ""
    @State private var results: [AppResult] = []
    @State private var betas: [Beta] = []
    @State private var betaCatalogLoaded = false
    @State private var searched = false
    private struct StoreIntent {
        enum Kind { case download, versions, license }
        let app: AppResult
        let kind: Kind
        var version: String? = nil
        var job: LocalJob? = nil
    }
    @State private var pendingStoreIntent: StoreIntent?
    @State private var accountsFor: Flow?
    @State private var importing = false
    @State private var importingFor: LocalJob?
    @State private var showCredentials = false
    @State private var credentialOwner: String?
    @State private var credentialImport: URL?
    @State private var versionApp: AppResult?
    @State private var sharing: ShareFile?
    @State private var webSharing: ShareFile?
    @State private var acquire: AppResult?
    @State private var acquiringFor: LocalJob?
    @State private var deleting: LocalJob?
    @FocusState private var enteringSearch: Bool

    private var busy: Bool { model.action != nil }
    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanBeta: String { beta.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        TabView(selection: $page) {
            NavigationStack {
                acquisition
                    .navigationTitle("获取 IPA")
                    .navigationDestination(for: AppSelection.self) { selection in
                        AppDetailView(model: model, selection: selection,
                            onDownload: { startDownload($0) }, onVersions: { requestVersions($0) },
                            onAcquire: { requestLicense($0, job: nil) })
                    }
                    .toolbar { accountToolbar }
            }
            .tabItem { Label("获取 IPA", systemImage: "arrow.down.circle.fill") }
            .tag(0)

            NavigationStack {
                history
                    .navigationTitle("处理记录")
                    .toolbar { accountToolbar }
            }
            .tabItem { Label("处理记录", systemImage: "clock.fill") }
            .tag(1)
        }
        .tint(Color(uiColor: .systemBlue))
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--recovery-verification-check") { model.askingCode = true }
            #endif
        }
        .sheet(item: $accountsFor, onDismiss: accountsClosed) { Accounts(model: model, betaSelected: $0 == .beta) }
        .sheet(isPresented: Binding(get: { model.askingCode && accountsFor == nil && versionApp == nil },
                                    set: { if !$0 { model.finishCode(nil) } }), onDismiss: { model.finishCode(nil) }) {
            VerificationSheet(model: model)
        }
        .sheet(isPresented: $showCredentials, onDismiss: { credentialImport = nil }) {
            CredentialsSheet(model: model, owner: credentialOwner, incomingFile: credentialImport)
        }
        .sheet(item: $versionApp, onDismiss: presentPendingCredential) { app in
            VersionPicker(model: model, app: app) { version in
                versionApp = nil
                startDownload(app, version: version)
            }
            .sheet(isPresented: Binding(get: { model.askingCode }, set: { if !$0 { model.finishCode(nil) } }),
                   onDismiss: { model.finishCode(nil) }) { VerificationSheet(model: model) }
        }
        .onChange(of: model.storeConnected) { connected in
            if connected && pendingStoreIntent != nil && accountsFor == .store { accountsFor = nil }
        }
        .onChange(of: model.country) { _ in resetSearch() }
        .onChange(of: model.accounts.activeStore) { _ in resetSearch(); acquire = nil; versionApp = nil }
        .onChange(of: model.accounts.activeBeta) { account in
            betas = []; beta = ""; betaCatalogLoaded = false
            if account != nil { flow = .beta }
        }
        .task(id: "\(flow.rawValue)-\(model.accounts.activeBeta?.uuidString ?? "none")") {
            guard flow == .beta, model.betaConnected, !busy else { return }
            await loadBetaCatalog()
        }
        .sheet(item: $sharing, onDismiss: presentPendingCredential) { SharedIPA(file: $0.url) }
        .sheet(item: $webSharing, onDismiss: presentPendingCredential) { WebShareSheet(file: $0.url) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
            let previous = importingFor
            importingFor = nil
            if case .failure(let error as NSError) = result, error.code == NSUserCancelledError { return }
            do { startImport(try result.get(), replacing: previous) }
            catch { model.message = model.friendly(error) }
        }
        .onOpenURL { receiveFile($0) }
        .alert("操作提示", isPresented: Binding(get: { model.message != nil && accountsFor == nil },
                                                set: { if !$0 { model.message = nil } })) {
            if model.storeNeedsReauth, model.message == "App Store 会话已失效，请重新登录。" {
                Button("重新登录 App Store") {
                    model.message = nil
                    accountsFor = .store
                }
            }
            Button("好", role: .cancel) {}
        } message: { Text(model.message ?? "") }
        .confirmationDialog("获取免费授权", isPresented: Binding(get: { acquire != nil }, set: {
            if !$0 { acquire = nil; acquiringFor = nil }
        }), presenting: acquire) { app in
            if let job = acquiringFor {
                Button("获取授权并重试下载") {
                    run("正在获取授权") {
                        try await model.acquire(app)
                        model.action = "正在下载 IPA"
                        try await model.download(app, version: job.version, replacing: job)
                    }
                }
            } else {
                Button("为此账户获取") {
                    run("正在获取授权") { try await model.acquire(app); model.message = "已获取授权，可以下载。" }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("Apple 会把这个免费 App 加到当前账户的购买记录。")
        }
        .confirmationDialog("删除处理记录？", isPresented: Binding(get: { deleting != nil },
                                                           set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { job in
            Button("删除记录和文件", role: .destructive) {
                do { try model.removeJob(job) }
                catch { model.message = model.friendly(error) }
            }
            Button("取消", role: .cancel) {}
        } message: { job in
            Text("将删除「\(job.name)」的记录及 IPA 解密 保存的相关文件。")
        }
    }

    private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Apple 账户", systemImage: "person.crop.circle") {
                accountsFor = flow == .beta ? .beta : .store
            }.disabled(busy)
        }
    }

    private var acquisition: some View {
        List {
            Section {
                Picker("来源", selection: $flow) {
                    ForEach(Flow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(busy)
            }

            switch flow {
            case .store: storeSection
            case .beta: betaSection
            case .local:
                Section {
                    Button("从文件导入 IPA", systemImage: "folder") { chooseIPA() }.disabled(busy)
                    Button("管理 FairPlay 凭据", systemImage: "key") { openCredentials(nil) }.disabled(busy)
                } footer: {
                    Text("导入后的文件会出现在处理记录。")
                }
            }

            if let action = model.action, page == 0 {
                Section { busyRow(action) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var storeSection: some View {
        Section {
            TextField("名称、App ID、Bundle ID 或商店链接", text: $query)
                .accessibilityLabel("App Store 搜索")
                .focused($enteringSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: query) { _ in resetSearch() }
                .onSubmit(search)
                .disabled(busy)
            Button("搜索 App Store", systemImage: "magnifyingglass", action: search)
                .disabled(cleanQuery.isEmpty || busy)
        } footer: {
            NavigationLink { RegionPicker(model: model) } label: {
                Label("搜索地区 · \(Storefronts.name(model.country))", systemImage: "globe")
            }.disabled(busy)
        }

        if !model.storeConnected {
            Section {
                Label(model.storeNeedsReauth
                    ? (model.canAttemptStoreOperation ? "会话已过期，下次操作时自动重新登录。" : "会话已失效，请重新登录。")
                    : "搜索无需登录，下载需登录 App Store。", systemImage: "person.crop.circle.badge.exclamationmark")
                Button("App Store 账户设置") { accountsFor = .store }.disabled(busy)
            }
        }
        if searched {
            Section("搜索结果 · \(results.count)") {
                if results.isEmpty {
                    Label("没找到匹配的 App", systemImage: "magnifyingglass").foregroundStyle(.secondary)
                }
                ForEach(results) { app in
                    HStack(spacing: 10) {
                        NavigationLink(value: AppSelection(app: app, country: model.country)) { AppListingLabel(app: app) }
                        Menu {
                            Button("下载最新版", systemImage: "arrow.down") { startDownload(app) }
                            Button("选择历史版本", systemImage: "clock.arrow.circlepath") { requestVersions(app) }
                            if app.price == 0 { Button("获取免费授权", systemImage: "person.badge.plus") { requestLicense(app, job: nil) } }
                        } label: { Image(systemName: "arrow.down.circle").font(.title2).frame(width: 44, height: 44) }
                        .accessibilityLabel("下载选项，\(app.trackName)").disabled(busy)
                    }
                }
            }
        }
    }

    @ViewBuilder private var betaSection: some View {
        if model.betaConnected {
            Section {
                TextField("已获邀 App 的 Bundle ID", text: $beta)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(busy)
                Button("下载测试版 IPA", systemImage: "arrow.down") { startBeta(cleanBeta, bundle: cleanBeta) }
                    .disabled(cleanBeta.isEmpty || busy)
            }
            Section("我的测试") {
                Button("读取测试列表", systemImage: "arrow.clockwise") {
                    Task { await loadBetaCatalog() }
                }
                .disabled(busy)
                if betaCatalogLoaded && betas.isEmpty {
                    Text("当前账户没有返回可用的测试 App。").foregroundStyle(.secondary)
                }
                ForEach(betas) { item in
                    Button {
                        startBeta(item.name, bundle: item.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).foregroundStyle(.primary)
                                Text(item.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .accessibilityHint("下载此测试版 IPA")
                    .disabled(busy)
                }
            }
        } else {
            Section {
                Button("登录 TestFlight", systemImage: "person.crop.circle") { accountsFor = .beta }
            } footer: {
                Text("登录后可以查看已获邀的测试 App。")
            }
        }
    }

    private var history: some View {
        List {
            if let action = model.action, model.downloads.isEmpty {
                Section { busyRow(action) }
            }
            if model.jobs.isEmpty {
                Section {
                    Label("还没有处理记录", systemImage: "tray").foregroundStyle(.secondary)
                    Button("下载或导入 IPA") { page = 0 }
                }
            } else {
                Section {
                    ForEach(model.jobs) { job in historyRow(job) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func historyRow(_ job: LocalJob) -> some View {
        let original = model.artifact(job, clear: false)
        let decrypted = model.artifact(job, clear: true)
        let active = job.state == .downloading || job.state == .decrypting
        let canAcquire = job.needsStoreLicense && job.storeApp?.price == 0 && model.canAttemptStoreOperation && original == nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let app = job.storeApp { AppArtwork(app: app, size: 44) }
                else { Image(systemName: statusIcon(job.state)).foregroundStyle(statusColor(job.state)).font(.title3).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.headline)
                    Text("\(job.source) · \(job.state.title)").font(.subheadline).foregroundStyle(.secondary)
                    if let version = job.version {
                        Text("版本 ID \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if !active {
                    Menu {
                        if let decrypted {
                            Button("导出解密版", systemImage: "square.and.arrow.up") { sharing = ShareFile(url: decrypted) }
                            Button("网页下载", systemImage: "network") { webSharing = ShareFile(url: decrypted) }
                        }
                        if let original {
                            Button("导出原始包", systemImage: "doc.zipper") { sharing = ShareFile(url: original) }
                            if job.state != .ready {
                                Button("管理凭据", systemImage: "key") { openCredentials(owner(for: job)) }
                            }
                        } else if job.state == .failed {
                            if canAcquire {
                                Button("重试下载", systemImage: "arrow.clockwise") { recoverDownload(job) }
                            }
                            if job.flow == .store {
                                if model.storeConnected {
                                    Button("切换 App Store 账户", systemImage: "person.crop.circle") { accountsFor = .store }
                                } else if job.needsStoreLicense, job.storeApp == nil {
                                    Button("登录 App Store", systemImage: "person.crop.circle") { accountsFor = .store }
                                }
                            } else if job.flow == .beta, model.betaConnected {
                                Button("管理 TestFlight 账户", systemImage: "person.crop.circle") { accountsFor = .beta }
                            }
                        }
                        Button("删除记录", systemImage: "trash", role: .destructive) { deleting = job }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("更多操作，\(job.name)")
                    .disabled(busy)
                }
            }
            if let account = job.credentialOwner { Text("下载账户 · " + account).font(.caption).foregroundStyle(.secondary) }
            if let progress = model.downloads[job.id] {
                DownloadProgressView(progress: progress)
            }
            if let note = job.note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if !active {
                if let decrypted {
                    recordAction("共享解密版", "square.and.arrow.up") { sharing = ShareFile(url: decrypted) }
                } else if original != nil, job.state == .failed || job.state == .imported {
                    if model.hasCredentials(for: job) {
                        recordAction(job.state == .failed ? "重试解密" : "解密 IPA", "lock.open") {
                            run("正在解密") { try await model.decrypt(job) }
                        }
                    } else {
                        recordAction("导入 FairPlay 凭据", "key") { openCredentials(owner(for: job)) }
                    }
                } else if job.state == .failed {
                    if canAcquire, let app = job.storeApp {
                        recordAction("获取免费授权", "person.badge.plus") { requestLicense(app, job: job) }
                    } else {
                        let action = recoveryAction(job)
                        recordAction(action.title, action.icon) { recoverDownload(job) }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func recordAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .buttonStyle(.borderless)
            .font(.subheadline)
            .frame(minHeight: 44, alignment: .leading)
            .disabled(busy)
    }

    private func statusIcon(_ state: LocalJob.State) -> String {
        switch state {
        case .downloading: return "arrow.down.circle"
        case .imported: return "doc.zipper"
        case .decrypting: return "lock.open"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func statusColor(_ state: LocalJob.State) -> Color {
        switch state {
        case .failed: return Color(uiColor: .systemRed)
        case .ready: return Color(uiColor: .systemGreen)
        default: return .secondary
        }
    }

    private func recoveryAction(_ job: LocalJob) -> (title: String, icon: String) {
        switch job.flow {
        case .store:
            if job.needsStoreLicense, job.storeApp == nil { return ("重新搜索 App", "magnifyingglass") }
            if !model.canAttemptStoreOperation {
                return (model.storeNeedsReauth ? "重新登录 App Store" : "登录 App Store", "person.crop.circle")
            }
            return job.storeApp == nil ? ("重新搜索 App", "magnifyingglass") : ("重试下载", "arrow.clockwise")
        case .beta:
            if !model.betaConnected { return ("登录 TestFlight", "person.crop.circle") }
            return job.retryBetaBundle == nil ? ("打开 TestFlight 下载页", "paperplane") : ("重试下载", "arrow.clockwise")
        case .local, nil: return ("重新导入 IPA", "folder")
        }
    }

    private func recoverDownload(_ job: LocalJob) {
        switch job.flow {
        case .store:
            if job.storeApp == nil, job.needsStoreLicense || model.storeConnected {
                flow = .store
                query = job.name
                page = 0
                search()
            } else if let app = job.storeApp {
                startDownload(app, version: job.version, replacing: job)
            } else {
                accountsFor = .store
            }
        case .beta:
            guard model.betaConnected else { accountsFor = .beta; return }
            if let bundle = job.retryBetaBundle {
                startBeta(job.name, bundle: bundle, replacing: job)
            } else {
                flow = .beta
                page = 0
            }
        case .local, nil:
            chooseIPA(replacing: job.flow == .local ? job : nil)
        }
    }

    private func requestVersions(_ app: AppResult) {
        guard model.canAttemptStoreOperation else {
            pendingStoreIntent = StoreIntent(app: app, kind: .versions)
            accountsFor = .store; return
        }
        versionApp = app
    }

    private func accountsClosed() {
        let pending = pendingStoreIntent
        pendingStoreIntent = nil
        if model.storeConnected, let pending {
            switch pending.kind {
            case .download: startDownload(pending.app, version: pending.version, replacing: pending.job)
            case .versions: versionApp = pending.app
            case .license: requestLicense(pending.app, job: pending.job)
            }
        }
        presentPendingCredential()
    }

    private func owner(for job: LocalJob) -> String? {
        guard job.flow == .store || job.flow == .beta else { return nil }
        return job.credentialOwner ?? model.activeProfile(beta: job.flow == .beta)?.owner
    }

    private func openCredentials(_ owner: String?) {
        credentialOwner = owner
        showCredentials = true
    }

    private func requestLicense(_ app: AppResult, job: LocalJob?) {
        guard model.canAttemptStoreOperation else {
            pendingStoreIntent = StoreIntent(app: app, kind: .license, job: job)
            accountsFor = .store; return
        }
        acquiringFor = job
        acquire = app
    }

    private func busyRow(_ title: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(model.automaticStoreLoginStatus ?? title).foregroundStyle(.secondary)
        }
    }

    private func run(_ title: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        enteringSearch = false
        model.action = title
        Task {
            defer { model.action = nil }
            do { try await operation() }
            catch { model.message = model.friendly(error) }
        }
    }

    private func startDownload(_ app: AppResult, version: String? = nil, replacing job: LocalJob? = nil) {
        guard model.canAttemptStoreOperation else {
            pendingStoreIntent = StoreIntent(app: app, kind: .download, version: version, job: job)
            accountsFor = .store; return
        }
        page = 1
        run("正在下载 IPA") { try await model.download(app, version: version, replacing: job) }
    }

    private func loadBetaCatalog() async {
        guard !busy, let account = model.accounts.activeBeta else { return }
        model.action = "正在读取测试列表"
        defer { model.action = nil }
        do {
            let result = try await model.betaCatalog()
            guard model.accounts.activeBeta == account else { return }
            betas = result
            betaCatalogLoaded = true
        } catch is CancellationError { }
        catch { model.message = model.friendly(error) }
    }

    private func startBeta(_ title: String, bundle: String, replacing job: LocalJob? = nil) {
        page = 1
        run("正在下载测试版") { try await model.downloadBeta(title, bundle: bundle, replacing: job) }
    }

    private func chooseIPA(replacing job: LocalJob? = nil) {
        importingFor = job
        importing = true
    }

    private func receiveFile(_ source: URL) {
        guard FileImportSafety.kind(of: source) != nil else {
            model.message = "请选择本地 IPA 文件或 credential.bin。"; return
        }
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AppFileLibrary.receive(source)
                }.value
                if FileImportSafety.kind(of: url) == .ipa { startImport(url); return }
                credentialImport = url
                credentialOwner = model.activeProfile(beta: flow == .beta)?.owner ?? model.activeProfile(beta: true)?.owner
                let dismissing = accountsFor != nil || versionApp != nil || sharing != nil || webSharing != nil || importing
                accountsFor = nil; versionApp = nil; sharing = nil; webSharing = nil; importing = false
                model.message = nil
                if !dismissing { showCredentials = true }
            } catch { model.message = model.friendly(error) }
        }
    }

    private func presentPendingCredential() {
        if credentialImport != nil { showCredentials = true }
    }

    private func startImport(_ url: URL, replacing job: LocalJob? = nil) {
        page = 1
        run("正在导入 IPA") { try await model.importIPA(url, replacing: job) }
    }

    private func resetSearch() {
        results = []
        searched = false
    }

    private func search() {
        let term = cleanQuery
        let country = model.country
        guard !term.isEmpty else { return }
        run("正在搜索") {
            let matches = try await model.catalog(term)
            guard cleanQuery == term, model.country == country else { return }
            results = matches
            searched = true
        }
    }
}

private struct DownloadProgressView: View {
    let progress: DownloadProgress

    private var label: String {
        if progress.preparingPackage { return "传输完成，正在整理 IPA…" }
        if !progress.transferring { return "正在获取下载信息…" }
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        guard progress.total > 0 else { return "已下载 \(received)" }
        let total = ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)
        return "\(received) / \(total)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack {
                Text(label)
                Spacer()
                if let fraction = progress.fraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.tint(Color(uiColor: .systemBlue))
    }
}

@MainActor private struct Accounts: View {
    @ObservedObject var model: LocalLab
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var betaSelected: Bool
    @State private var addingAccount = false
    @State private var showCredentials = false
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var rememberPassword = false
    @State private var hasSavedPassword = false
    @State private var filledSavedPassword = false
    @State private var signingIn = false
    @State private var useInitialCode = false
    @State private var betaSMS = false
    @State private var nativeBetaMode = true
    @State private var initialCode = ""
    @State private var problem: String?
    @State private var diagnostic: String?
    @State private var accountAction = false

    var connected: Bool { betaSelected ? model.betaConnected : model.storeConnected }
    private var canSwitchFromSMS: Bool {
        guard betaSelected, betaSMS, let diagnostic else { return false }
        return diagnostic.hasPrefix("testflight-auth/sms-send HTTP ")
            || diagnostic == "testflight-auth/trusted-phones HTTP 202"
            || diagnostic == "testflight-auth/trusted-phones HTTP 403"
    }

    private var canRetryTestFlight: Bool {
        guard betaSelected, !connected, let diagnostic, !testFlightExchangeRejected else { return false }
        return diagnostic.hasPrefix("testflight-store/") || diagnostic.hasPrefix("testflight-session/")
    }

    private var testFlightExchangeRejected: Bool {
        betaSelected && diagnostic?.hasPrefix("testflight-session/exchange-rejected") == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("服务", selection: $betaSelected) {
                    Text("App Store").tag(false)
                    Text("TestFlight").tag(true)
                }.pickerStyle(.segmented).disabled(signingIn)
                    .onChange(of: betaSelected) { _ in
                        addingAccount = false
                        email = ""
                        password = ""
                        showPassword = false
                        rememberPassword = false
                        hasSavedPassword = false
                        problem = nil
                        diagnostic = nil
                    }
                authenticationSection
                if !betaSelected {
                    Section {
                        Toggle("会话过期后自动重新登录", isOn: $model.automaticStoreLogin)
                    } header: { Text("会话恢复") } footer: {
                        Text("仅使用此设备已保存的账户密码。需要验证码时会提示输入；失败后停止自动尝试。")
                    }
                }
                Section("FairPlay") {
                    Button("管理凭据", systemImage: "key") { showCredentials = true }.disabled(signingIn)
                    Text("已保存 \(model.keyCount) 个凭据").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        RegionPicker(model: model)
                    } label: {
                        LabeledContent("搜索地区", value: Storefronts.name(model.country))
                    }.disabled(signingIn || model.action != nil)
                }
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Section { LabeledContent("IPA 解密", value: version).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Apple 账户").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(signingIn) } }
            .interactiveDismissDisabled(signingIn)
        }
        .tint(Color(uiColor: .systemBlue))
        .task(id: betaSelected) {
            if !betaSelected, model.storeNeedsReauth {
                email = model.activeProfile(beta: false)?.email ?? ""
            }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { showPassword = false } }
        .sheet(isPresented: $showCredentials) {
            CredentialsSheet(model: model, owner: model.activeProfile(beta: betaSelected)?.owner)
        }
        .sheet(isPresented: $model.askingCode, onDismiss: { model.finishCode(nil) }) {
            VerificationSheet(model: model)
        }
    }

    private var authenticationSection: some View {
                Section(betaSelected ? "TestFlight" : "App Store") {
                    if betaSelected ? !model.accounts.beta.isEmpty : !model.accounts.store.isEmpty {
                        ForEach(betaSelected ? model.accounts.beta : model.accounts.store) { profile in
                            Button {
                                do {
                                    try model.switchAccount(profile.id, beta: betaSelected)
                                    addingAccount = false
                                    problem = nil
                                    if profile.needsReauth == true { email = profile.email; password = "" }
                                }
                                catch { problem = model.friendly(error) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.email)
                                        if profile.needsReauth == true {
                                            Text("待重新登录").foregroundStyle(.secondary).font(.caption)
                                        }
                                        if let country = Storefronts.country(for: profile.storefront) {
                                            Text(Storefronts.name(country)).foregroundStyle(.secondary).font(.caption)
                                        }
                                    }
                                    Spacer()
                                    if model.activeProfile(beta: betaSelected)?.id == profile.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(uiColor: .systemBlue))
                                            .accessibilityLabel("当前账户")
                                    }
                                }
                            }.disabled(signingIn || model.action != nil)
                        }
                        Button(addingAccount ? "取消添加" : "添加 Apple 账户",
                               systemImage: addingAccount ? "xmark" : "person.badge.plus") {
                            addingAccount.toggle(); email = ""; password = ""; problem = nil; diagnostic = nil
                        }.disabled(signingIn || model.action != nil)
                        Button("退出当前账户", role: .destructive) {
                            do { try model.signOut(beta: betaSelected) }
                            catch { problem = model.friendly(error) }
                        }.disabled(signingIn || model.action != nil)
                    }
                    if !connected || addingAccount {
                        TextField("Apple 账户", text: $email).keyboardType(.emailAddress)
                            .textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .disabled(signingIn)
                            .onChange(of: email) { _ in
                                if filledSavedPassword { password = ""; filledSavedPassword = false }
                                problem = nil
                                diagnostic = nil
                                accountAction = false
                                showPassword = false
                                rememberPassword = false
                                hasSavedPassword = model.savedPassword(for: email) != nil
                            }
                        passwordFields
                        if betaSelected {
                            Toggle("设备验证登录（实验）", isOn: $nativeBetaMode).disabled(signingIn)
                            if !nativeBetaMode { Toggle("使用短信验证码", isOn: $betaSMS).disabled(signingIn) }
                        }
                        if !betaSelected || nativeBetaMode {
                            Toggle("我已收到验证码", isOn: $useInitialCode).disabled(signingIn)
                            if useInitialCode {
                                TextField("6 位验证码", text: $initialCode).keyboardType(.numberPad)
                                    .textContentType(.oneTimeCode).disabled(signingIn)
                            }
                        }
                        Button(signingIn ? "正在连接 Apple…" : testFlightExchangeRejected ? "重新验证 Apple 账户" : "登录") {
                            signIn(nativeBeta: betaSelected && nativeBetaMode)
                        }
                            .disabled(signingIn || email.isEmpty || password.isEmpty || model.action != nil ||
                                      ((!betaSelected || nativeBetaMode) && useInitialCode && !validCode(initialCode)))
                        if betaSelected && nativeBetaMode {
                            Text("此方式使用受信任设备验证码，请保持 App 在前台。关闭开关可使用原登录方式与短信验证。真实账户登录仍待验证。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    if let diagnostic {
                        Text(diagnostic).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !connected, let action = model.action {
                        Text("\(action)，完成后可登录。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if canRetryTestFlight {
                        Button("重试建立 TestFlight 会话") { retryTestFlight() }
                            .disabled(signingIn || model.action != nil)
                    }
                    if canSwitchFromSMS {
                        Button("改用受信任设备验证") {
                            betaSMS = false
                            problem = nil
                            diagnostic = nil
                        }
                    }
                    if accountAction {
                        Link("检查 Apple 账户", destination: URL(string: "https://account.apple.com/")!)
                    }
                }
    }

    @ViewBuilder private var passwordFields: some View {
        HStack {
            Group {
                if showPassword { TextField("密码", text: $password) }
                else { SecureField("密码", text: $password) }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
        }.disabled(signingIn)
        Toggle("在此设备保存密码", isOn: $rememberPassword).disabled(signingIn)
        if hasSavedPassword {
            Button("使用已保存密码") {
                guard let saved = model.savedPassword(for: email) else { return }
                password = saved
                filledSavedPassword = true
                showPassword = false
                rememberPassword = true
            }.disabled(signingIn)
            Button("忘记已保存密码", role: .destructive) {
                do {
                    try model.forgetPassword(for: email)
                    password = ""
                    filledSavedPassword = false
                    showPassword = false
                    rememberPassword = false
                    hasSavedPassword = false
                } catch { problem = model.friendly(error) }
            }.disabled(signingIn)
        }
    }

    private func validCode(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private func retryTestFlight() {
        let account = email
        signingIn = true
        problem = nil
        diagnostic = nil
        Task {
            defer { signingIn = false }
            do {
                try await model.retryBetaSession(email: account)
                password = ""
                filledSavedPassword = false
                addingAccount = false
            } catch let issue as StoreIssue {
                problem = issue.message
                diagnostic = issue.diagnostic
            } catch { problem = model.friendly(error) }
        }
    }

    private func signIn(nativeBeta: Bool = false) {
        let user = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        let savePassword = rememberPassword
        let beta = betaSelected
        let verification = (!beta || nativeBeta) && useInitialCode ? initialCode : ""
        problem = nil
        diagnostic = nil
        accountAction = false
        signingIn = true
        showPassword = false
        Task {
            defer { signingIn = false; initialCode = "" }
            do {
                try await model.login(email: user, password: secret, beta: beta, initialCode: verification, betaSMS: betaSMS, nativeBeta: nativeBeta)
                password = ""
                filledSavedPassword = false
                addingAccount = false
                if savePassword {
                    do {
                        try model.savePassword(secret, for: user)
                        hasSavedPassword = true
                    } catch {
                        problem = "登录已完成。\(model.friendly(error))"
                    }
                }
            } catch let issue as StoreIssue {
                problem = issue.message
                diagnostic = issue.diagnostic
                accountAction = issue.requiresAccountAction
            } catch {
                problem = model.friendly(error)
            }
        }
    }
}

@MainActor private struct VerificationSheet: View {
    @ObservedObject var model: LocalLab
    @State private var code = ""
    @State private var selectedPhone: Int64?
    @State private var lastSMSPhone: Int64?
    var body: some View {
            NavigationStack {
                Form {
                    if model.pickingBetaPhone {
                        betaPhoneChoices
                    } else {
                        Section {
                            Text("输入 Apple 发送的 6 位验证码。")
                            TextField("验证码", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                            Button("提交验证码") { model.finishCode(code) }
                                .disabled(!validCode(code) || model.codeDeliveryBusy)
                        }
                    }
                    if model.storeCodeDelivery { codeDeliveryOptions }
                }.navigationTitle("双重认证").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.finishCode(nil) } } }
            }.presentationDetents(model.storeCodeDelivery || model.pickingBetaPhone ? [.large] : [.medium])
    }
    private var codeDeliveryOptions: some View {
        Section("没有收到验证码？") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(model.nextCodeRequest.timeIntervalSince(context.date))))
                VStack(alignment: .leading, spacing: 16) {
                    Button("重新发送到受信任设备") {
                        model.requestStoreCode(method: .trustedDevice)
                    }.buttonStyle(.borderless).disabled(model.codeDeliveryBusy || remaining > 0)

                    if model.codePhones.isEmpty {
                        Button("选择受信任手机号") {
                            model.requestStoreCode(method: .sms)
                        }.buttonStyle(.borderless).disabled(model.codeDeliveryBusy || remaining > 0)
                    } else {
                        Picker("受信任手机号", selection: $selectedPhone) {
                            Text("请选择").tag(nil as Int64?)
                            ForEach(Array(model.codePhones.enumerated()), id: \.element.id) { index, phone in
                                Text(phone.displayNumber.isEmpty ? "受信任号码 \(index + 1)" : phone.displayNumber)
                                    .tag(Optional(phone.id))
                            }
                        }.disabled(model.codeDeliveryBusy)
                        Button(selectedPhone != nil && selectedPhone == lastSMSPhone ? "再次发送短信" : "发送短信") {
                            guard let selectedPhone else { return }
                            lastSMSPhone = selectedPhone
                            model.requestStoreCode(method: .sms, phoneID: selectedPhone)
                        }.buttonStyle(.borderless)
                            .disabled(selectedPhone == nil || model.codeDeliveryBusy || remaining > 0)
                    }
                    if remaining > 0 {
                        Text("\(remaining) 秒后可再次发送").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            if model.codeDeliveryBusy { ProgressView("正在向 Apple 请求…") }
            if let message = model.codeDeliveryMessage {
                Text(message).font(.footnote).foregroundStyle(model.codeDeliveryFailed ? Color.red : Color.secondary)
            }
            if let diagnostic = model.codeDeliveryDiagnostic {
                Text(diagnostic).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var betaPhoneChoices: some View {
        Section("选择短信接收号码") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(model.nextCodeRequest.timeIntervalSince(context.date))))
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.codePhones.enumerated()), id: \.element.id) { index, phone in
                        let number = phone.displayNumber.isEmpty ? "受信任号码 \(index + 1)" : phone.displayNumber
                        Button(phone.id == lastSMSPhone ? "重新发送到 \(number)" : number) {
                            lastSMSPhone = phone.id
                            model.selectBetaPhone(phone.id)
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 32, alignment: .leading)
                        .disabled(model.codeDeliveryBusy || remaining > 0)
                    }
                    if remaining > 0 {
                        Text("\(remaining) 秒后可再次发送").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if model.codeDeliveryBusy { ProgressView("正在向 Apple 请求验证码…") }
            if let message = model.codeDeliveryMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if let diagnostic = model.codeDeliveryDiagnostic {
                Text(diagnostic).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.betaCanUseTrustedDevice {
                Button("改用受信任设备验证") { model.selectBetaPhone(0) }
            }
        }
    }

    private func validCode(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

private struct ShareFile: Identifiable { let url: URL; var id: URL { url } }
private struct SharedIPA: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor private struct CredentialsSheet: View {
    @ObservedObject var model: LocalLab
    @Environment(\.dismiss) private var dismiss
    @State var owner: String?
    var incomingFile: URL? = nil
    @State private var importedFile: URL?
    @State private var reading = false
    @State private var hex = ""
    @State private var revealHex = false
    @State private var importing = false
    @State private var status: String?
    @State private var failed = false
    @State private var query = ""
    private var groups: [CredentialContentGroup] { CredentialContentGroup.make(model.credentials) }
    private var visible: [CredentialContentGroup] {
        groups.filter { query.isEmpty || ([$0.displayName, $0.fingerprint] + $0.owners).joined(separator: " ").localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("账户标签", selection: $owner) {
                        Text("未绑定").tag(nil as String?)
                        if let owner, !model.credentialOwners.contains(owner) { Text(owner).tag(Optional(owner)) }
                        ForEach(model.credentialOwners, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    if let incomingFile {
                        Text("已收到文件：\(incomingFile.lastPathComponent)").font(.footnote)
                        Button("导入收到的凭据", systemImage: "key") { importCredential(incomingFile) }
                            .disabled(reading || importedFile == incomingFile)
                    }
                    Button("选择 credential.bin", systemImage: "doc.badge.plus") { importing = true }
                        .disabled(reading || importing)
                    if reading { ProgressView("正在读取并校验…") }
                    HStack {
                        Group {
                            if revealHex { TextField("32 位十六进制凭据", text: $hex) }
                            else { SecureField("32 位十六进制凭据", text: $hex) }
                        }.textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { revealHex.toggle() } label: { Image(systemName: revealHex ? "eye.slash" : "eye") }
                            .accessibilityLabel(revealHex ? "隐藏十六进制" : "显示十六进制")
                    }
                    Button("保存十六进制凭据") { importHex() }
                        .disabled(reading || hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let status { Text(status).font(.footnote).foregroundStyle(failed ? Color.red : Color.secondary) }
                } header: { Text("导入凭据") } footer: {
                    Text("credential.bin 为 16 字节，等价于 32 位十六进制字符。账户标签可手动设置，不代表来源已经验证；相同内容只显示一份，保留各账户标签。")
                }
                Section {
                    TextField("搜索名称、账户标签或指纹", text: $query)
                    ForEach(visible) { group in
                        NavigationLink {
                            CredentialDetail(model: model, contentID: group.contentID)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.displayName).font(.headline)
                                Text(group.owners.isEmpty ? "未绑定账户标签" : group.owners.joined(separator: "、")).font(.footnote).foregroundStyle(.secondary)
                                Text(group.evidence.isEmpty ? "尚未校验本机 IPA" : "已校验 \(group.evidence.count) 条许可证")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                    if groups.isEmpty { Text("尚无凭据，可导入 Mac 提取的 credential.bin 或粘贴十六进制。").foregroundStyle(.secondary) }
                    else if visible.isEmpty { Text("没有匹配的凭据。").foregroundStyle(.secondary) }
                } header: { Text("已保存 \(groups.count) 份不同凭据") }
                if !groups.isEmpty {
                    Section {
                        Button(model.verifyingCredentials ? "正在校验…" : "校验全部凭据与本机 IPA", systemImage: "checkmark.shield") { verifyAll() }
                            .disabled(reading || model.verifyingCredentials)
                    } footer: { Text("只读取已下载或导入的原始 IPA，在本机验证许可证，不会上传凭据。") }
                }
            }
            .navigationTitle("FairPlay 凭据").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .tint(Color(uiColor: .systemBlue))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): importCredential(url)
            case .failure(let error as NSError) where error.code == NSUserCancelledError: break
            case .failure(let error): status = model.friendly(error); failed = true
            }
        }
        .onDisappear { hex = ""; revealHex = false }
    }
    private func imported(_ id: UUID, duplicate: Bool) async {
        failed = false
        status = duplicate ? "相同凭据已存在，已保留账户标签。" : "凭据已保存。"
        guard !model.verifyingCredentials, let data = model.credentials.first(where: { $0.id == id })?.data else { return }
        do {
            let count = try await model.verifyCredentials(data: data)
            status = count > 0 ? "凭据已保存，已校验 \(count) 条本机 IPA 许可证。" : "凭据已保存，当前本机 IPA 尚无匹配许可证。"
        } catch { status = "凭据已保存。" + model.friendly(error) }
    }
    private func importHex() {
        reading = true; status = nil
        Task {
            defer { reading = false }
            do {
                let before = groups.count
                let id = try model.addCredential(hex: hex, owner: owner)
                hex = ""; revealHex = false
                await imported(id, duplicate: groups.count == before)
            } catch { status = model.friendly(error); failed = true }
        }
    }
    private func importCredential(_ url: URL) {
        guard !reading else { return }
        let selectedOwner = owner
        reading = true; status = nil
        Task {
            defer { reading = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try CredentialFileReader.read(url) }.value
                let duplicate = model.credentials.contains { $0.data == data }
                let id = try model.addCredential(data, owner: selectedOwner, origin: "文件导入 · " + String(url.lastPathComponent.prefix(120)))
                importedFile = url
                await imported(id, duplicate: duplicate)
            } catch { status = model.friendly(error); failed = true }
        }
    }
    private func verifyAll() {
        Task {
            do { let count = try await model.verifyCredentials(); status = "本次匹配 \(count) 条许可证，校验记录已更新。"; failed = false }
            catch { status = model.friendly(error); failed = true }
        }
    }
}

@MainActor private struct CredentialDetail: View {
    @ObservedObject var model: LocalLab
    let contentID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var reveal = false
    @State private var status: String?
    @State private var failed = false
    @State private var deleting = false
    @State private var sharing: ShareFile?
    @State private var exportFolder: URL?
    private var group: CredentialContentGroup? { CredentialContentGroup.make(model.credentials).first { $0.contentID == contentID } }

    var body: some View {
        Form {
            if let group {
                Section("凭据名称") {
                    TextField("名称或备注", text: $name)
                    Button("保存名称") { attempt { try model.renameCredential(group.id, label: name) } }
                        .disabled(name == (group.records.first(where: { $0.label != nil })?.label ?? ""))
                }
                Section("凭据内容") {
                    HStack {
                        Text(reveal ? group.records[0].hex : "••••••••••••••••••••••••••••••••")
                            .font(.footnote.monospaced()).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                            .accessibilityLabel(reveal ? "隐藏凭据" : "显示凭据")
                    }
                    Button("复制十六进制", systemImage: "doc.on.doc") { UIPasteboard.general.string = group.records[0].hex; status = "已复制 32 位十六进制凭据。"; failed = false }
                    Button("导出 credential.bin", systemImage: "square.and.arrow.up") { export(group.data) }
                    LabeledContent("SHA-256 短指纹", value: group.fingerprint).font(.footnote.monospaced())
                    Text("指纹用于识别内容，不是凭据本身。十六进制文本与 credential.bin 保存相同的 16 字节数据。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(group.records) { record in
                        Menu {
                            Button("设为未绑定") { attempt { try model.moveCredential(record.id, to: nil) } }
                            ForEach(model.credentialOwners, id: \.self) { owner in
                                Button(owner) { attempt { try model.moveCredential(record.id, to: owner) } }
                            }
                        } label: { LabeledContent("账户标签", value: record.owner ?? "未绑定") }
                    }
                    if !model.credentialOwners.isEmpty {
                        Menu("添加账户标签", systemImage: "person.badge.plus") {
                            ForEach(model.credentialOwners, id: \.self) { owner in
                                Button(owner) { attempt { try model.addCredential(group.data, owner: owner, origin: "手动账户标签") } }
                            }
                        }
                    }
                } header: { Text("账户标签") } footer: { Text("标签是手动管理信息，不能仅从凭据反查 Apple ID 邮箱。下载任务账户和实际许可证匹配结果见下方。") }
                Section("来源信息") {
                    ForEach(group.origins, id: \.self) { Text($0).font(.footnote) }
                    if group.origins.isEmpty { Text("旧版凭据未记录导入来源。").foregroundStyle(.secondary) }
                    if let date = group.records.compactMap(\.addedAt).min() { LabeledContent("首次添加", value: date.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section {
                    Button(model.verifyingCredentials ? "正在校验…" : "校验本机 IPA", systemImage: "checkmark.shield") { verify(group.data) }
                        .disabled(model.verifyingCredentials)
                    if group.evidence.isEmpty { Text("尚未记录匹配许可证。可先下载或导入原始 IPA，再进行校验。").foregroundStyle(.secondary) }
                    ForEach(Array(group.evidence.enumerated()), id: \.offset) { _, proof in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(proof.appName).font(.headline)
                            if !proof.bundleID.isEmpty { Text(proof.bundleID).font(.caption).foregroundStyle(.secondary) }
                            Text("user " + proof.user + " / key " + proof.key).font(.caption.monospaced())
                            if let source = proof.sourceName { Text("来源 IPA：" + source).font(.caption) }
                            if let owner = proof.downloadOwner { Text("下载任务账户：" + owner).font(.caption) }
                            else { Text("下载账户未确认").font(.caption).foregroundStyle(.secondary) }
                            if let date = proof.verifiedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }
                } header: { Text("许可证校验记录") } footer: { Text("记录证明该凭据可解开对应 IPA 的许可证。账户标签和校验证据分开展示；旧标签不会自动变为已验证。") }
                if let status { Section { Text(status).font(.footnote).foregroundStyle(failed ? Color.red : Color.secondary) } }
                Section { Button("删除此凭据及全部账户标签", role: .destructive) { deleting = true } }
            } else { Text("此凭据已移除。") }
        }
        .navigationTitle("凭据详情").navigationBarTitleDisplayMode(.inline)
        .onAppear { name = group?.records.first(where: { $0.label != nil })?.label ?? "" }
        .onDisappear { reveal = false }
        .confirmationDialog("删除此凭据及全部账户标签？", isPresented: $deleting, titleVisibility: .visible) {
            if let group { Button("删除凭据", role: .destructive) { do { try model.removeCredentialContent(group.data); dismiss() } catch { status = model.friendly(error); failed = true } } }
            Button("取消", role: .cancel) { }
        }
        .sheet(item: $sharing, onDismiss: clearExport) { SharedIPA(file: $0.url) }
    }
    private func attempt(_ operation: () throws -> Void) {
        do { try operation(); status = "已保存更改。"; failed = false }
        catch { status = model.friendly(error); failed = true }
    }
    private func verify(_ data: Data) {
        Task {
            do { let count = try await model.verifyCredentials(data: data); status = count > 0 ? "本次校验匹配 \(count) 条许可证。" : "当前本机 IPA 没有匹配许可证。"; failed = false }
            catch { status = model.friendly(error); failed = true }
        }
    }
    private func export(_ data: Data) {
        do {
            clearExport()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialExport-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            exportFolder = folder
            let file = folder.appendingPathComponent("credential.bin")
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            sharing = ShareFile(url: file)
        } catch { clearExport(); status = "导出失败，请确认设备已解锁及存储空间充足。"; failed = true }
    }
    private func clearExport() { if let folder = exportFolder { try? FileManager.default.removeItem(at: folder) }; exportFolder = nil }
}

@MainActor private struct RegionPicker: View {
    @ObservedObject var model: LocalLab
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    row("自动 · " + Storefronts.name(model.automaticCountry), code: "")
                } footer: {
                    Text("优先使用已登录账户的 App Store 地区。")
                }
            }
            ForEach(Storefronts.regions.filter {
                query.isEmpty || Storefronts.name($0).localizedStandardContains(query) || $0.uppercased() == query.uppercased()
            }, id: \.self) { code in
                row(Storefronts.name(code) + " · " + code.uppercased(), code: code)
            }
        }
        .navigationTitle("搜索地区")
        .searchable(text: $query, prompt: "搜索国家或地区")
    }

    private func row(_ title: String, code: String) -> some View {
        Button {
            model.region = code
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if model.region == code { Image(systemName: "checkmark") }
            }
        }
    }
}

@MainActor private struct VersionPicker: View {
    @ObservedObject var model: LocalLab
    @Environment(\.dismiss) private var dismiss
    let app: AppResult
    let download: (String) -> Void
    @State private var query = ""
    @State private var manual = ""
    @State private var versions: StoreVersionList?
    @State private var selection: String?
    @State private var names: [String: String] = [:]
    @State private var message: String?
    @State private var loading = false
    @State private var readingVersion: String?

    private var filtered: [String] { (versions?.ids ?? []).filter { query.isEmpty || $0.contains(query) || (names[$0]?.localizedCaseInsensitiveContains(query) ?? false) } }
    private var downloadID: String? {
        let value = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return selection }
        return value.allSatisfy { $0.isASCII && $0.isNumber } ? value : nil
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    AppListingLabel(app: app)
                }
                if loading { ProgressView("正在读取 Apple 提供的版本…") }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }.disabled(loading)
                }
                Section("指定版本") {
                    TextField("输入版本 ID（可选）", text: $manual).keyboardType(.numberPad)
                    if !manual.isEmpty && downloadID == nil { Text("版本 ID 只能包含数字。").font(.caption).foregroundStyle(.red) }
                }
                if let versions, !versions.ids.isEmpty {
                    Section {
                        ForEach(filtered, id: \.self) { version in
                            Button { selection = version } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let name = names[version] { Text(name).font(.headline) }
                                        Text("版本 ID \(version)").font(.subheadline.monospacedDigit())
                                        if version == versions.latest { Text("最新版").font(.caption).foregroundStyle(.secondary) }
                                    }.foregroundStyle(.primary)
                                    Spacer()
                                    if version == readingVersion { ProgressView().controlSize(.small) }
                                    if version == selection { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                    } header: { Text("选择版本") } footer: { Text("点选版本可读取版本号。") }
                }
            }
            .searchable(text: $query, prompt: "筛选版本号或版本 ID")
            .navigationTitle("历史版本").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if let downloadID { download(downloadID) }
                } label: {
                    Text("下载所选版本").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(downloadID == nil)
                    .padding().background(.regularMaterial)
            }
            .task { await load() }
            .task(id: selection) {
                guard let selection, names[selection] == nil else { return }
                readingVersion = selection
                defer { if readingVersion == selection { readingVersion = nil } }
                if let name = try? await model.versionName(selection, for: app), !name.isEmpty, !Task.isCancelled {
                    names[selection] = name
                }
            }
        }.tint(Color(uiColor: .systemBlue))
    }

    private func load() async {
        loading = true
        message = nil
        defer { loading = false }
        do {
            let list = try await model.versions(for: app)
            guard !Task.isCancelled else { return }
            versions = list
            if list.ids.isEmpty { message = "Apple 未返回可用的版本。" }
            if let latest = list.latest, let name = app.version,
               Storefronts.country(for: model.activeProfile(beta: false)?.storefront) == model.country {
                names[latest] = name
            }
        } catch {
            if !Task.isCancelled { message = model.friendly(error) }
        }
    }
}

@MainActor private struct WebShareSheet: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var server: LANShareServer?
    @State private var link: URL?
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(file.lastPathComponent).font(.headline)
                    Text("让另一台设备连接同一局域网，然后在浏览器打开下载地址。下载时请让 IPA 解密 留在前台。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let link {
                    Section("下载地址") {
                        Text(link.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
                        Button(copied ? "已复制" : "复制地址", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = link.absoluteString
                            copied = true
                        }
                        ShareLink(item: link) { Label("发送地址", systemImage: "square.and.arrow.up") }
                    }
                } else if server != nil {
                    ProgressView("正在开启网页下载…")
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if server == nil {
                    Button("开启网页下载", systemImage: "wifi") { start() }
                } else {
                    Button("停止网页下载", role: .destructive) { stop() }
                }
            }
            .navigationTitle("网页下载").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .tint(Color(uiColor: .systemBlue))
        .onDisappear { stop() }
        .onChange(of: phase) { value in
            if value == .background && server != nil {
                stop()
                message = "App 已进入后台，网页下载已停止。"
            }
        }
    }

    private func start() {
        message = nil
        copied = false
        do {
            let newServer = try LANShareServer(file: file)
            server = newServer
            newServer.start { [weak newServer] result in
                Task { @MainActor in
                    guard let newServer, server === newServer else { return }
                    switch result {
                    case .success(let url): link = url
                    case .failure:
                        stop()
                        message = "网页下载无法启动。请检查 Wi-Fi 和 IPA 解密 的本地网络权限。"
                    }
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func stop() {
        server?.stop()
        server = nil
        link = nil
    }
}

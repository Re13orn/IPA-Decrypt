import AppKit
import AppleAuth
import SwiftUI
import UniformTypeIdentifiers

@main struct IPADecryptMac: App {
    @StateObject private var model = LocalLab()
    init() {
        if ProcessInfo.processInfo.arguments.contains("--store-runtime-check") {
            do {
                try StoreRuntime.checkEngine()
                print("mac-store-runtime-check: passed"); fflush(stdout); exit(0)
            } catch {
                print("mac-store-runtime-check: failed " + error.localizedDescription); fflush(stdout); exit(1)
            }
        }
    }
    var body: some Scene {
        WindowGroup("IPA 解密") {
            MacWorkspace(model: model).frame(minWidth: 980, minHeight: 660)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--launch-check") {
                        print("mac-launch-check: passed"); fflush(stdout)
                        NSApplication.shared.terminate(nil)
                    }
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
            MacWorkspaceCommands()
        }
    }
}

enum MacPage: String, CaseIterable, Identifiable {
    case store = "App Store", beta = "TestFlight", history = "处理记录", credentials = "FairPlay 凭据", enrollment = "本机凭据提取", device = "越狱设备提取"
    var id: String { rawValue }
    var icon: String {
        switch self { case .store: return "square.stack"; case .beta: return "paperplane"; case .history: return "clock"; case .credentials: return "key"; case .enrollment: return "desktopcomputer.and.arrow.down"; case .device: return "iphone.and.arrow.forward" }
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
    @ObservedObject var queue: MacProcessingQueue
    @ObservedObject private var modalContext = MacCommandContext.shared
    @State private var workspaceVerification = false
    init(model: LocalLab) { self.model = model; self.queue = model.taskQueue }
    @State private var page: MacPage? = .store
    @State private var query = ""
    @State private var results: [AppResult] = []
    @State private var searched = false
    @State private var resultTerm = ""
    @State private var searchProblem: String?
    @State private var searchRequest = LatestViewRequest()
    @State private var searchLoading = false
    @State private var catalogTask: Task<Void, Never>?
    @State private var feedback: String?
    @State private var downloadPreparation: MacDownloadPlan?
    private enum PreparationAction { case credentials(MacDownloadPlan), accounts(MacDownloadPlan) }
    private enum CredentialReturn {
        case download(MacDownloadPlan), job(UUID, String)
        var name: String { switch self { case .download(let plan): return plan.name; case .job(_, let name): return name } }
    }
    @State private var preparationAction: PreparationAction?
    @State private var planAfterLogin: MacDownloadPlan?
    @State private var planAfterVersion: MacDownloadPlan?
    @State private var credentialReturn: CredentialReturn?
    @State private var historyQuery = ""
    @State private var historyFilter: JobListFilter = .all
    @State private var testsLoaded = false
    @State private var testsProblem: String?
    @State private var testsNeedReauth = false
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
    @State private var selectedCredential: UUID?
    @State private var selectedApp: UInt64?
    private enum SearchField: Hashable { case store, history }
    @FocusState private var searchFocus: SearchField?
    @State private var focusStoreOnAppear = false

    var body: some View {
        workspaceWithPresentations
        .focusedSceneValue(\.macWorkspaceActions, MacWorkspaceActions(
            navigate: { if !deviceBusy { page = $0 } },
            find: focusSearch, refresh: refreshPage, importIPA: importIPA,
            canNavigate: !deviceBusy && !presentingSheet,
            canRefresh: !presentingSheet && ((page == .store && !searchLoading && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (page == .beta && model.action == nil && model.betaConnected)),
            canImport: !presentingSheet && !deviceBusy))
        .onChange(of: model.accounts.activeBeta) { tests = []; testsLoaded = false; testsProblem = nil; testsNeedReauth = false }
        .onChange(of: model.country) {
            catalogTask?.cancel(); searchRequest.invalidate(); searchLoading = false
            results = []; selectedApp = nil; searched = false; searchProblem = nil
        }
        .onDisappear { catalogTask?.cancel() }
        .onChange(of: model.askingCode) { updateVerificationPresentation() }
        .onChange(of: modalContext.modal) { updateVerificationPresentation() }
        .onChange(of: model.action) { continueWhenIdle() }
        .onChange(of: presentingSheet) { continueWhenIdle() }
        .onOpenURL { url in
            guard ["ipa", "bin"].contains(url.pathExtension.lowercased()) else { return }
            guard !presentingSheet && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil else {
                model.message = "请先完成或关闭当前窗口，再打开此文件。"; return
            }
            if url.pathExtension.lowercased() == "ipa" {
                queue.enqueueImport(url); showHistory()
                feedback = queue.storageProblem ?? "已加入导入队列。"
            } else if model.action == nil { incomingCredential = url; page = .credentials }
            else { model.message = "请等待当前任务完成后，再打开凭据文件。" }
        }
    }
    private var workspaceLayout: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("获取与处理") {
                    ForEach([MacPage.store, .beta, .history]) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }
                Section("账户与设备") {
                    ForEach([MacPage.credentials, .enrollment, .device]) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                }
                Section {
                    Button("导入本地 IPA…", systemImage: "square.and.arrow.down") { importIPA() }
                        .buttonStyle(.plain).disabled(deviceBusy)
                }
            }.disabled(deviceBusy).listStyle(.sidebar).navigationTitle("IPA 解密")
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 260)
        } detail: {
            Group {
                switch page ?? .store {
                case .store: storeView
                case .beta: betaView
                case .history: historyView
                case .credentials: MacCredentials(model: model, incomingFile: $incomingCredential, selected: $selectedCredential, extractLocal: { page = .enrollment }, extractDevice: { page = .device }, useCredentials: continueWithCredentials, continuationTitle: credentialReturn == nil ? nil : "继续原任务")
                case .enrollment: MacEnrollmentView(model: model, viewCredential: openCredential, useCredentials: continueWithCredentials, continuationTitle: credentialReturn == nil ? nil : "继续原任务")
                case .device: CredentialExtractionView(model: model, viewCredential: openCredential, useCredentials: continueWithCredentials, continuationTitle: credentialReturn == nil ? nil : "继续原任务")
                }
            }.navigationTitle((page ?? .store).rawValue)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let target = credentialReturn {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("继续处理：" + target.name).font(.callout.weight(.medium))
                            Text(model.credentials.isEmpty ? "从本机提取、越狱设备提取或导入已有凭据。" : "凭据已准备，可返回原任务按许可证验证。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("继续原任务", action: continueWithCredentials).buttonStyle(.borderedProminent)
                            .disabled(model.credentials.isEmpty || deviceBusy)
                        Button("取消返回") { credentialReturn = nil }.buttonStyle(.borderless)
                    }.padding(12).background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let feedback {
                    HStack(spacing: 10) {
                        Label(feedback, systemImage: "checkmark.circle").font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { self.feedback = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("关闭提示").accessibilityLabel("关闭提示")
                    }.padding(12).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let action = model.action { HStack { ProgressView().controlSize(.small); Text(model.automaticStoreLoginStatus ?? action).font(.caption) } }
                }
                ToolbarItem {
                    if page == .store || page == .beta {
                        ServiceAccountMenu(model: model, beta: page == .beta, compact: true) {
                            loginBeta = page == .beta; login = true
                        }.menuStyle(.borderlessButton)
                    } else {
                        Button("账户设置…", systemImage: "person.crop.circle") { loginBeta = false; login = true }
                            .help("管理 App Store 与 TestFlight 账户").disabled(model.action != nil)
                    }
                }
            }
        }
    }
    private var workspaceWithPresentations: some View {
        workspaceLayout
        .sheet(item: $detail, onDismiss: continueDetailAction) { selected in
            NavigationStack {
                AppDetailView(model: model, selection: selected,
                    onDownload: { detailAction = .download($0); detail = nil },
                    onVersions: { detailAction = .versions($0); detail = nil },
                    onAcquire: { detailAction = .acquire($0); detail = nil })
                    .toolbar { ToolbarItem { Button("关闭") { detail = nil }.keyboardShortcut(.cancelAction) } }
            }.frame(width: 860, height: 760)
        }
        .sheet(item: $downloadPreparation, onDismiss: continuePreparation) { plan in
            MacDownloadPreparation(model: model, plan: plan, enqueue: { decrypt in
                guard let owner = model.activeProfile(beta: plan.beta)?.owner else { return }
                let added = queue.enqueue(plan.operation(owner: owner, decrypt: decrypt))
                feedback = added ? "已加入任务队列。" : (queue.storageProblem ?? "队列中已有相同任务。")
                credentialReturn = nil; downloadPreparation = nil; showHistory()
            }, credentials: { decrypt in
                var next = plan; next.decryptAfterwards = decrypt
                preparationAction = .credentials(next); downloadPreparation = nil
            }, accounts: { decrypt in
                var next = plan; next.decryptAfterwards = decrypt
                preparationAction = .accounts(next); downloadPreparation = nil
            }, cancel: { downloadPreparation = nil })
        }
        .sheet(isPresented: $login, onDismiss: resumeAccountActions) { MacAccounts(model: model, beta: $loginBeta) }
        .onChange(of: model.storeConnected) { if model.storeConnected && pendingStoreRequest != nil && login { login = false } }
        .sheet(isPresented: $workspaceVerification, onDismiss: { model.finishCode(nil) }) {
            MacVerification(model: model)
        }
        .sheet(item: $version, onDismiss: {
            if let plan = planAfterVersion { planAfterVersion = nil; downloadPreparation = plan }
        }) { selection in
            MacVersionPicker(model: model, selection: selection) { value in
                planAfterVersion = MacDownloadPlan(name: selection.app.trackName, app: selection.app, version: value)
                version = nil
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
    }
    private var storeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("名称、App ID、Bundle ID 或商店链接", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocus, equals: .store)
                    .onSubmit(search).accessibilityLabel("搜索 App Store")
                if searchLoading { ProgressView().controlSize(.small).accessibilityLabel("正在搜索") }
                Button("搜索", action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchLoading)
                Menu {
                    Button("自动 · " + Storefronts.name(model.automaticCountry)) { model.region = "" }
                    Divider()
                    ForEach(Storefronts.regions, id: \.self) { country in
                        Button(Storefronts.name(country)) { model.region = country }
                    }
                } label: { Label(Storefronts.name(model.country), systemImage: "globe") }
                .disabled(searchLoading)
            }.padding()
            Divider()
            if model.storeNeedsReauth {
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
            if let searchProblem {
                HStack(spacing: 12) {
                    Label(searchProblem, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("重试", action: search).disabled(searchLoading)
                }.padding(12).background(Color.orange.opacity(0.08))
            }
            if searchLoading && results.isEmpty { Spacer(); ProgressView("正在搜索 App Store…"); Spacer() }
            else if results.isEmpty { ContentUnavailableView(searched ? "未找到应用" : "查找 App Store 应用", systemImage: "magnifyingglass", description: Text(searched ? "请尝试其他名称、应用链接或商店地区。" : "输入应用名称、App ID、Bundle ID 或 App Store 链接。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                HStack {
                    Text("“\(resultTerm)” · \(results.count) 个结果").lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("点击应用查看详情").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal).padding(.vertical, 8)
                List(results, selection: $selectedApp) { app in
                    HStack(spacing: 14) {
                        Button { detail = AppSelection(app: app, country: model.country) } label: { AppListingLabel(app: app) }
                            .buttonStyle(.plain).accessibilityLabel("查看详情，\(app.trackName)")
                        Button("下载 IPA") { requestStore(app, kind: .latest) }
                            .help("下载最新版 \(app.trackName)")
                        Menu {

                            Button("最新版本") { requestStore(app, kind: .latest) }
                            Button("选择历史版本…") { requestStore(app, kind: .versions) }
                            if app.price == 0 { Button("获取免费授权") { requestStore(app, kind: .acquire) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("更多选项，\(app.trackName)").help("历史版本与免费授权")
                        .disabled(model.action != nil)
                    }.padding(.vertical, 4).tag(app.id)
                    .contextMenu {
                        Button("查看详情") { detail = AppSelection(app: app, country: model.country) }
                        Divider()
                        Button("下载最新版本") { requestStore(app, kind: .latest) }
                        Button("选择历史版本…") { requestStore(app, kind: .versions) }.disabled(model.action != nil)
                        Button("复制 Bundle ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(app.bundleId, forType: .string)
                            feedback = "已复制 Bundle ID。"
                        }
                    }
                }
                .onKeyPress(.return) {
                    guard let app = results.first(where: { $0.id == selectedApp }) else { return .ignored }
                    detail = AppSelection(app: app, country: model.country)
                    return .handled
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if focusStoreOnAppear { searchFocus = .store; focusStoreOnAppear = false }
        }
    }
    private var betaView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(testsLoaded ? "\(tests.count) 个 App" : "已加入的测试").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { loadTests() }.disabled(!model.betaConnected || model.action != nil)
            }.fixedSize(horizontal: false, vertical: true).padding()
            Divider()
            if let testsProblem, !tests.isEmpty {
                HStack {
                    Label(testsProblem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                    Button("账户设置") { loginBeta = true; login = true }.disabled(model.action != nil)
                }.padding()
            }
            Group {
            if !model.betaConnected {
                ContentUnavailableView {
                    Label("登录 TestFlight", systemImage: "paperplane")
                } description: {
                    Text("使用已加入测试的 Apple 账户读取应用列表。")
                } actions: {
                    Button("登录 TestFlight") { loginBeta = true; login = true }.buttonStyle(.borderedProminent).disabled(model.action != nil)
                }
            } else if model.action == "正在读取测试目录" {
                Spacer(); ProgressView("正在读取测试列表…"); Spacer()
            } else if tests.isEmpty {
                ContentUnavailableView {
                    Label(testsProblem != nil ? "无法读取测试列表" : testsLoaded ? "暂无可用测试" : "读取测试列表", systemImage: testsProblem != nil ? "exclamationmark.circle" : "paperplane")
                } description: {
                    Text(testsProblem ?? (testsLoaded ? "当前账户未返回可用的测试 App，可更换账户或稍后刷新。" : "刷新列表以查看此账户加入的测试。"))
                } actions: {
                    if testsNeedReauth {
                        Button("重新验证 TestFlight") { loginBeta = true; login = true }.buttonStyle(.borderedProminent).disabled(model.action != nil)
                    }
                    Button("刷新列表") { loadTests() }.disabled(model.action != nil)
                    if !testsNeedReauth { Button("账户设置") { loginBeta = true; login = true }.disabled(model.action != nil) }
                }
            } else {
                List(tests) { app in
                    HStack(spacing: 14) {
                        Image(systemName: "app.badge").font(.title2).foregroundStyle(.secondary).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) { Text(app.name).font(.headline); Text(app.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Spacer()
                        Button("下载 IPA") { downloadPreparation = MacDownloadPlan(name: app.name, bundle: app.id) }
                    }.padding(.vertical, 8)
                }
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.accounts.activeBeta) { if model.betaConnected { loadTests() } }
    }
    private var visibleJobs: [LocalJob] { model.jobs.filter { historyFilter.includes($0, query: historyQuery) } }
    private var historyView: some View {
        VStack(spacing: 0) {
            if !queue.operations.isEmpty || queue.storageProblem != nil {
                MacQueuePanel(model: model, queue: queue, prepareCredentials: prepareCredentials, manageAccount: manageQueueAccount)
                Divider()
            }
            HStack(spacing: 12) {
                TextField("搜索名称、版本或 Bundle ID", text: $historyQuery).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索处理记录").focused($searchFocus, equals: .history)
                Picker("状态", selection: $historyFilter) {
                    ForEach(JobListFilter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                Text("\(visibleJobs.count) 项").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding()
            Divider()
            Group {
            if model.jobs.isEmpty { ContentUnavailableView("尚无处理记录", systemImage: "tray", description: Text("从商店下载或导入本地 IPA 后，进度与结果会显示在这里。")) }
            else if visibleJobs.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的记录", systemImage: "line.3.horizontal.decrease.circle")
                } description: { Text("尝试其他关键词或切换处理状态。") } actions: {
                    Button("显示全部记录") { historyQuery = ""; historyFilter = .all }
                }
            }
            else { List(visibleJobs) { job in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Image(systemName: job.state == .ready ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.circle" : "doc.zipper").foregroundStyle(job.state == .ready ? Color.green : .secondary); Text(job.name).font(.headline); Spacer(); Text(job.state.title).foregroundStyle(.secondary) }
                    Text(job.source + (job.version.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                    if let account = job.credentialOwner { Text("下载账户 · " + account).font(.caption).foregroundStyle(.secondary) }
                    if let progress = model.downloads[job.id] {
                        Text(progress.preparingPackage ? "正在整理 IPA 文件…" : progress.transferring ? "正在下载原包…" : "正在获取下载信息…")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: progress.fraction)
                        Text(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file) + (progress.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file) : "")).font(.caption.monospacedDigit())
                    }
                    if let note = job.note { Text(note).font(.callout).foregroundStyle(job.state == .failed ? .red : .secondary).textSelection(.enabled) }
                    if model.artifact(job, clear: false) != nil && model.artifact(job, clear: true) == nil && !model.hasCredentials(for: job) {
                        HStack {
                            Label("导入匹配的 FairPlay 凭据后可解密。", systemImage: "key").foregroundStyle(.secondary)
                            Button("获取凭据并继续") { prepareCredentials(job) }
                        }.font(.callout)
                    }
                    historyActions(job)
                }.padding(.vertical, 10).fixedSize(horizontal: false, vertical: true)
            } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func historyActions(_ job: LocalJob) -> some View {
        HStack(spacing: 10) {
            if let decrypted = model.artifact(job, clear: true) {
                Button("导出解密版", systemImage: "square.and.arrow.up") { export(decrypted) }.buttonStyle(.borderedProminent).disabled(model.action != nil)
            } else if model.artifact(job, clear: false) != nil {
                if model.hasCredentials(for: job) {
                    Button(job.state == .failed ? "重试解密" : "解密 IPA", systemImage: "lock.open") { queue.enqueueDecryption(job) }.buttonStyle(.borderedProminent)
                }
            } else if job.state == .failed, let app = job.storeApp {
                if job.needsStoreLicense && app.price == 0 {
                    Button("获取免费授权并重试") { requestStore(app, kind: .acquire, replacing: job) }
                } else {
                    Button("重新下载", systemImage: "arrow.clockwise") { requestStore(app, kind: .latest, replacing: job, version: job.version) }
                }
            } else if job.state == .failed, let bundle = job.retryBetaBundle {
                Button("重新下载", systemImage: "arrow.clockwise") {
                    downloadPreparation = MacDownloadPlan(name: job.name, bundle: bundle, replacing: job)
                }
            }
            Menu("更多操作") {
                if let original = model.artifact(job, clear: false) { Button("导出原始包") { export(original) } }
                if let decrypted = model.artifact(job, clear: true) {
                    Button("网页下载") { share(decrypted) }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([decrypted]) }
                    if model.hasCredentials(for: job) { Button("重新解密") { queue.enqueueDecryption(job) } }
                }
                if let original = model.artifact(job, clear: false) {
                    Button("在 Finder 中显示原包") { NSWorkspace.shared.activateFileViewerSelecting([original]) }
                }
                Button("管理凭据") { prepareCredentials(job) }
                if job.flow == .store || job.flow == .beta { Button("账户设置") { loginBeta = job.flow == .beta; login = true } }
                Divider()
                Button("删除记录及文件…", role: .destructive) { removing = job }
            }.fixedSize().accessibilityLabel("更多操作，\(job.name)").disabled(model.action != nil)
        }.controlSize(.regular)
    }
    private func openCredential(_ id: UUID) { selectedCredential = id; page = .credentials }
    private func continueWithCredentials() {
        switch credentialReturn {
        case .download(let plan): downloadPreparation = plan
        case .job(let id, _):
            if let job = model.jobs.first(where: { $0.id == id }), model.artifact(job, clear: true) == nil { queue.enqueueDecryption(job) }
            credentialReturn = nil; showHistory()
        case nil: if model.jobs.isEmpty { page = .store } else { showHistory() }
        }
    }
    private func prepareCredentials(_ job: LocalJob) { credentialReturn = .job(job.id, job.name); page = .credentials }
    private func continuePreparation() {
        guard let action = preparationAction else { return }
        preparationAction = nil
        switch action {
        case .credentials(let plan): credentialReturn = .download(plan); page = .credentials
        case .accounts(let plan): planAfterLogin = plan; loginBeta = plan.beta; login = true
        }
    }
    private func resumeAccountActions() {
        resumeStoreRequest()
        if let plan = planAfterLogin { planAfterLogin = nil; downloadPreparation = plan }
    }
    private func manageQueueAccount(_ operation: MacQueuedOperation) {
        do { try queue.selectRequiredAccount(operation) } catch { model.message = model.friendly(error) }
        if queue.waitingReason(operation) != nil { loginBeta = operation.kind == .beta; login = true }
    }
    private func showHistory() { historyFilter = .all; historyQuery = ""; page = .history }
    private var presentingSheet: Bool {
        login || downloadPreparation != nil || detail != nil || version != nil || webFile != nil || model.askingCode || removing != nil || model.message != nil
    }
    private var deviceBusy: Bool {
        guard let action = model.action else { return false }
        return ["正在提取本机模型", "正在提取设备凭据", "正在测试设备连接", "正在扫描设备许可证", "正在提取所选许可证", "正在全部提取并去重"].contains(action)
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
        if case .latest = kind {
            downloadPreparation = MacDownloadPlan(name: app.trackName, app: app, version: version, replacing: replacing)
            return
        }
        let request = PendingStoreRequest(app: app, kind: kind, replacing: replacing, version: version)
        guard model.canAttemptStoreOperation else { pendingStoreRequest = request; loginBeta = false; login = true; return }
        performStoreRequest(request)
    }
    private func resumeStoreRequest() {
        guard let request = pendingStoreRequest else { return }
        pendingStoreRequest = nil
        if model.storeConnected { performStoreRequest(request) }
        else { continueWhenIdle() }
    }
    private func performStoreRequest(_ request: PendingStoreRequest) {
        switch request.kind {
        case .latest: downloadPreparation = MacDownloadPlan(name: request.app.trackName, app: request.app, version: request.version, replacing: request.replacing)
        case .versions: run("正在读取版本") { let versions = try await model.versions(for: request.app); version = VersionSelection(app: request.app, versions: versions) }
        case .acquire: run("正在请求授权") {
            try await model.acquire(request.app)
            feedback = "已获取 “" + request.app.trackName + "” 的免费授权。"
            if let job = request.replacing {
                downloadPreparation = MacDownloadPlan(name: request.app.trackName, app: request.app, version: job.version, replacing: job)
            }
        }
        }
    }
    private func focusSearch() {
        guard !deviceBusy else { return }
        if page == .history { searchFocus = .history }
        else if page == .store { searchFocus = .store }
        else { focusStoreOnAppear = true; page = .store }
    }
    private func refreshPage() {
        if page == .store { search() }
        else if page == .beta { loadTests() }
    }
    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty && !searchLoading else { return }
        let country = model.country
        let token = searchRequest.begin()
        searchProblem = nil; searchLoading = true
        catalogTask = Task { @MainActor in
            defer { if searchRequest.finish(token) { searchLoading = false } }
            do {
                let found = try await AppCatalog.search(term, country: country)
                guard searchRequest.contains(token), model.country == country else { return }
                results = found; resultTerm = term; searched = true
                if !found.contains(where: { $0.id == selectedApp }) { selectedApp = nil }
            } catch {
                guard !Task.isCancelled && searchRequest.contains(token), model.country == country else { return }
                searchProblem = model.friendly(error)
            }
        }
    }
    private func loadTests() {
        guard let account = model.accounts.activeBeta, model.action == nil, !presentingSheet else { return }
        model.action = "正在读取测试目录"; testsProblem = nil; testsNeedReauth = false
        Task {
            defer { model.action = nil; continueWhenIdle() }
            do {
                let entries = try await model.betaCatalog()
                guard model.accounts.activeBeta == account else { return }
                tests = entries; testsLoaded = true
            } catch {
                guard model.accounts.activeBeta == account else { return }
                testsProblem = model.friendly(error)
                testsNeedReauth = (error as? BetaCatalogFailure)?.requiresReauthentication == true
            }
        }
    }
    private func run(_ title: String, operation: @escaping @MainActor () async throws -> Void) {
        guard model.action == nil else { return }
        if page == .history && (title.contains("下载") || title.contains("解密") || title.contains("导入")) { historyFilter = .all; historyQuery = "" }
        feedback = nil
        model.action = title
        Task {
            defer { model.action = nil; continueWhenIdle() }
            do { try await operation() } catch { model.message = model.friendly(error) }
        }
    }
    private func updateVerificationPresentation() {
        if !model.askingCode { workspaceVerification = false; return }
        guard !workspaceVerification, !login, detail == nil, version == nil,
              downloadPreparation == nil, webFile == nil, removing == nil,
              model.message == nil, !MacCommandContext.hasModal else { return }
        workspaceVerification = true
    }
    private func continueWhenIdle() {
        // An explicitly requested download resumes before queued background work.
        guard model.action == nil, !presentingSheet, pendingStoreRequest == nil, detailAction == nil else { return }
        queue.startIfPossible()
        guard model.action == nil else { return }
        if MacCatalogLoading.shouldLoadBeta(visible: page == .beta, connected: model.betaConnected,
                    busy: false, loaded: testsLoaded, failed: testsProblem != nil) { loadTests() }
    }
    private func importIPA() {
        guard !deviceBusy else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard url.pathExtension.lowercased() == "ipa" else { model.message = "请选择 .ipa 格式的应用包。"; return }
            queue.enqueueImport(url); showHistory()
            feedback = queue.storageProblem ?? "已加入导入队列。"
        }
    }
    private func export(_ url: URL) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let destination = panel.url {
            run("正在导出 IPA") {
                do {
                    try await Task.detached(priority: .userInitiated) { try IPAFileExporter.copy(from: url, to: destination) }.value
                    feedback = "已导出 “" + destination.lastPathComponent + "”。"
                } catch { throw LabError("无法导出文件，请检查目标位置和剩余存储。") }
            }
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
    @Binding var beta: Bool
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
    @State private var addingAccount = false
    @State private var removingAccount = false
    @State private var success: String?
    private var profiles: [AppleProfile] { beta ? model.accounts.beta : model.accounts.store }
    private var service: String { beta ? "TestFlight" : "App Store" }
    private var showLogin: Bool { profiles.isEmpty || addingAccount || model.activeProfile(beta: beta)?.needsReauth == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Apple 账户").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy) }
            Picker("服务", selection: $beta) { Text("App Store").tag(false); Text("TestFlight").tag(true) }.pickerStyle(.segmented).disabled(busy)
            ScrollView {
                Form {
                    Section(service + " 账户") {
                        Text("App Store 与 TestFlight 可使用不同账户。").font(.caption).foregroundStyle(.secondary)
                        ForEach(profiles) { account in
                            HStack(spacing: 12) {
                                Button {
                                    do {
                                        try model.switchAccount(account.id, beta: beta)
                                        addingAccount = false; email = account.email; password = ""; code = ""; reveal = false
                                        problem = nil; diagnostic = nil; success = "已切换 " + service + " 下载账户。"
                                    } catch { show(error) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(account.email).lineLimit(1).truncationMode(.middle)
                                            Text(account.needsReauth == true ? "需重新登录" : model.activeProfile(beta: beta)?.id == account.id ? "当前下载账户" : "可切换")
                                                .font(.caption).foregroundStyle(account.needsReauth == true ? Color.orange : .secondary)
                                        }
                                        Spacer()
                                        if model.activeProfile(beta: beta)?.id == account.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                                Button("重新验证") { prepareLogin(account.email) }.buttonStyle(.borderless)
                            }
                        }
                        Button(addingAccount ? "取消登录表单" : "添加 " + service + " 账户", systemImage: addingAccount ? "xmark" : "person.badge.plus") {
                            if addingAccount { addingAccount = false; password = ""; code = ""; reveal = false }
                            else { prepareLogin("") }
                        }
                        if model.activeProfile(beta: beta) != nil {
                            Button("移除此服务的当前账户…", role: .destructive) { removingAccount = true }
                        }
                    }.disabled(busy || model.action != nil)
                    if showLogin {
                    Section(service + " 登录") {
                        if !beta && model.storeNeedsReauth { Text("当前 App Store 会话已失效。请选择账户并重新登录；仅切换账户不会刷新过期会话。").font(.caption).foregroundStyle(.orange) }
                        TextField("Apple 账户", text: $email).textContentType(.username)
                        HStack { Group { if reveal { TextField("密码", text: $password) } else { SecureField("密码", text: $password) } }; Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless) }
                        Toggle("在此 Mac 保存密码", isOn: $remember)
                        Button("填入已保存密码") { password = model.savedPassword(for: email) ?? "" }
                        if beta { Toggle("设备验证登录", isOn: $native); if !native { Toggle("使用短信验证码", isOn: $sms) } }
                        TextField("已有验证码（可留空）", text: $code).textContentType(.oneTimeCode)
                        Button(busy ? "正在登录…" : "登录") { signIn() }.buttonStyle(.borderedProminent).disabled(busy || email.isEmpty || password.isEmpty)
                        if beta { Button("重建 TestFlight 会话") { busy = true; Task { defer { busy = false }; do { try await model.retryBetaSession(email: email); problem = "会话已建立。" } catch { show(error) } } }.disabled(busy || email.isEmpty) }
                    }
                    }
                    if !beta {
                    Section("会话恢复") {
                        Toggle("会话过期后自动重新登录", isOn: $model.automaticStoreLogin)
                        Text("使用此 Mac 已保存的密码；需要验证码时提示输入，失败后停止自动尝试。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("搜索地区") {
                        Picker("地区", selection: $model.region) { Text("自动 · " + Storefronts.name(model.automaticCountry)).tag(""); ForEach(Storefronts.regions, id: \.self) { Text(Storefronts.name($0)).tag($0) } }
                    }
                    }
                    if let success { Label(success, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
                    if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                    if let diagnostic { Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled) }
                }.formStyle(.grouped)
            }
        }.padding(24).frame(width: 560, height: 680)
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $model.askingCode, onDismiss: { model.finishCode(nil) }) { MacVerification(model: model) }
        .onAppear { if email.isEmpty { email = model.activeProfile(beta: beta)?.email ?? "" } }
        .onChange(of: beta) { email = model.activeProfile(beta: beta)?.email ?? ""; password = ""; code = ""; reveal = false; remember = false; addingAccount = false; problem = nil; diagnostic = nil; success = nil }
        .onChange(of: email) { password = ""; code = ""; reveal = false; problem = nil; diagnostic = nil; success = nil }
        .onDisappear { password = ""; code = ""; reveal = false }
        .confirmationDialog("移除当前 " + service + " 账户？", isPresented: $removingAccount) {
            Button("移除账户", role: .destructive) {
                do { try model.signOut(beta: beta); email = model.activeProfile(beta: beta)?.email ?? ""; password = ""; code = ""; addingAccount = false; success = "已移除该服务的账户。" }
                catch { show(error) }
            }
        } message: { Text("将移除此 App 保存的该服务会话；另一服务的账户、已下载 IPA 和凭据不受影响。") }

    }
    private func prepareLogin(_ account: String) {
        email = account; password = ""; code = ""; reveal = false; remember = false
        problem = nil; diagnostic = nil; success = nil; addingAccount = true
    }
    private func show(_ error: Error) { problem = model.friendly(error); diagnostic = (error as? StoreIssue)?.diagnostic }
    private func signIn() {
        let user = email, secret = password, service = beta, save = remember, useNative = native, initial = code, useSMS = sms
        busy = true; problem = nil; diagnostic = nil; success = nil
        Task { defer { busy = false }; do { try await model.login(email: user, password: secret, beta: service, initialCode: initial, betaSMS: useSMS, nativeBeta: service && useNative); if save { try model.savePassword(secret, for: user) }; password = ""; code = ""; addingAccount = false; success = (service ? "TestFlight" : "App Store") + " 账户已登录。" } catch { show(error) } }
    }
}

@MainActor struct MacVerification: View {
    @ObservedObject var model: LocalLab
    @State private var code = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                Text("双重认证").font(.title2.bold())
                Text(model.pickingBetaPhone ? "选择用于接收验证码的受信任号码。" : "输入受信任设备上显示或短信收到的 6 位验证码。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity)
            if model.pickingBetaPhone {
                Text("选择短信接收号码")
                ForEach(Array(model.codePhones.enumerated()), id: \.element.id) { index, phone in Button(phone.displayNumber.isEmpty ? "受信任号码 \(index + 1)" : phone.displayNumber) { model.selectBetaPhone(phone.id) } }
                if model.betaCanUseTrustedDevice { Button("改用受信任设备") { model.selectBetaPhone(0) } }
            } else {
                VerificationCodeField(code: $code, submit: submitCode)
                    .frame(maxWidth: .infinity).disabled(model.codeDeliveryBusy)
                Button(action: submitCode) { Text("继续").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(code.count != 6 || model.codeDeliveryBusy).keyboardShortcut(.defaultAction)
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
                if model.codeDeliveryBusy { ProgressView("正在请求验证码…").controlSize(.small) }
                if let message = model.codeDeliveryMessage {
                    Text(message).font(.caption).foregroundStyle(model.codeDeliveryFailed ? Color.red : Color.secondary)
                }
            }
            Button("取消") { model.finishCode(nil) }.keyboardShortcut(.cancelAction).frame(maxWidth: .infinity)
        }.padding(32).frame(width: 420)
    }
    private func submitCode() {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }), !model.codeDeliveryBusy else { return }
        model.finishCode(code)
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
    @State private var nameRequest = LatestViewRequest()
    @State private var nameRequestTarget: String?
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
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("读取版本号") { if let target { Task { await readName(target) } } }.disabled(target == nil || loading)
                Button("下载所选版本") { if let target { download(target) } }.disabled(target == nil || loading).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 560, height: 640)
        .task {
            if let latest = selection.versions.latest, let name = selection.app.version,
               Storefronts.country(for: model.activeProfile(beta: false)?.storefront) == model.country { names[latest] = name }
        }
        .task(id: selected) { if !selected.isEmpty && names[selected] == nil { await readName(selected) } }
        .onChange(of: target) {
            if nameRequestTarget != target { nameRequest.invalidate(); loading = false; problem = nil }
        }
        .onDisappear { nameRequest.invalidate() }
    }
    private func readName(_ id: String) async {
        let token = nameRequest.begin()
        nameRequestTarget = id
        loading = true; problem = nil
        defer { if nameRequest.finish(token) { loading = false } }
        do {
            let name = try await model.versionName(id, for: selection.app)
            guard !Task.isCancelled && nameRequest.contains(token) && target == id else { return }
            if let name, !name.isEmpty { names[id] = name }
            else { problem = "此版本暂未提供版本号。" }
        } catch {
            if !Task.isCancelled && nameRequest.contains(token) && target == id { problem = model.friendly(error) }
        }
    }
}

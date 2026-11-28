import MacBridge
import Combine
import AppleAuth
import Foundation
import Security

enum Vault {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.ipadecrypt.mac.vault",
         kSecAttrAccount as String: name]
    }
    static func read(_ name: String) -> Data? {
        var args = query(name)
        args[kSecReturnData as String] = true
        args[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        guard SecItemCopyMatching(args as CFDictionary, &data) == errSecSuccess else { return nil }
        return data as? Data
    }
    static func remove(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
    static func randomBytes(length: Int) throws -> Data {
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!) }
        guard status == errSecSuccess else { throw LabError("无法生成设备本地密钥。") }
        return data
    }
}

struct StoreSessionStorage {
    let directory: URL
    private let stateKey = "ipatool-state"
    private let hardwareKey = "ipatool-hardware"

    func loadState() throws -> [String: Data] {
        guard let data = try read(stateKey) else { return [:] }
        return try JSONDecoder().decode([String: Data].self, from: data)
    }

    func saveState(_ state: [String: Data]) throws {
        try write(JSONEncoder().encode(state), as: stateKey)
    }

    func hardware() throws -> Data {
        if let data = try read(hardwareKey), data.count == 6 { return data }
        let data = try Vault.randomBytes(length: 6)
        try write(data, as: hardwareKey)
        return data
    }

    private func path(_ key: String) -> URL {
        directory.appendingPathComponent(key)
    }

    private func read(_ key: String) throws -> Data? {
        do {
            return try Data(contentsOf: path(key))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoSuchFileError {
            guard let previous = Vault.read(key) else { return nil }
            try write(previous, as: key)
            return previous
        }
    }

    private func write(_ data: Data, as key: String) throws {
        try data.write(to: path(key), options: [.atomic, .completeFileProtection])
        Vault.remove(key)
    }
}

enum Storefronts {
    private static let codes: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Storefronts", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let table = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()
    static var regions: [String] {
        Set(codes.values).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
    static var deviceCountry: String {
        let code = Locale.current.region?.identifier.lowercased() ?? ""
        return codes.values.contains(code) ? code : "us"
    }
    static func country(for storefront: String?) -> String? {
        guard let storefront else { return nil }
        let id = String(storefront.prefix { $0.isASCII && $0.isNumber })
        return codes[id]
    }
    static func name(_ country: String) -> String {
        let code = country.uppercased()
        return Locale(identifier: "zh-Hans").localizedString(forRegionCode: code) ?? code
    }
}

struct StoreVersionList {
    let ids: [String]
    let latest: String?
}

struct AppleProfile: Codable, Identifiable {
    var id = UUID()
    var email: String
    var storefront: String?
    var hardware: Data
    var state: [String: Data] = [:]
    var legacyBeta = false
    var needsReauth: Bool?
    var owner: String { email.lowercased() }
}

private struct StoreIdentity: Decodable {
    let email: String?
    let storeFront: String?
    let directoryServicesIdentifier: String?
    let passwordToken: String?
}

struct AccountBook: Codable {
    var store: [AppleProfile] = []
    var beta: [AppleProfile] = []
    var activeStore: UUID?
    var activeBeta: UUID?
}

@MainActor final class LocalLab: ObservableObject {
    @Published private(set) var jobs: [LocalJob] = []
    @Published private(set) var downloads: [UUID: DownloadProgress] = [:]
    @Published private(set) var accounts = AccountBook()
    @Published private(set) var credentials: [FairPlayCredential] = []
    var storeConnected: Bool { activeProfile(beta: false).map { $0.needsReauth != true } ?? false }
    var storeNeedsReauth: Bool { activeProfile(beta: false)?.needsReauth == true }
    var betaConnected: Bool { activeProfile(beta: true) != nil }
    var keyCount: Int { credentials.count }
    var credentialOwners: [String] {
        Set((accounts.store + accounts.beta).map(\.owner) + credentials.compactMap(\.owner)).sorted()
    }
    private let storeRecovery = StoreSessionRecovery()
    @Published var automaticStoreLogin = UserDefaults.standard.object(forKey: "automatic-store-login") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticStoreLogin, forKey: "automatic-store-login")
            if automaticStoreLogin { storeRecovery.resetFailures() }
        }
    }
    @Published private(set) var automaticStoreLoginStatus: String?
    var canAttemptStoreOperation: Bool {
        storeConnected || (automaticStoreLogin && activeProfile(beta: false).map { !storeRecovery.isBlocked($0.owner) && savedPassword(for: $0.email) != nil } == true)
    }
    @Published var action: String?
    @Published var message: String?
    @Published var askingCode = false
    @Published private(set) var storeCodeDelivery = false
    @Published private(set) var codePhones: [TrustedPhoneNumber] = []
    @Published private(set) var pickingBetaPhone = false
    @Published private(set) var betaCanUseTrustedDevice = false
    @Published private(set) var codeDeliveryDiagnostic: String?
    @Published private(set) var codeDeliveryBusy = false
    @Published private(set) var codeDeliveryMessage: String?
    @Published private(set) var codeDeliveryFailed = false
    @Published private(set) var nextCodeRequest = Date.distantPast
    private var codeRequest: CheckedContinuation<String, Error>?
    private var phoneRequest: CheckedContinuation<Int64, Error>?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryDevice: Device?
    private var deliveryID: UUID?
    private var storeResend: (() async throws -> StoreReply)?
    private var storeResendReply: StoreReply?
    private var deliveryCredentials: (email: String, password: String)?
    private let folder: URL
    lazy var taskQueue = MacProcessingQueue(model: self, file: folder.appendingPathComponent("processing-queue.json"))
    private struct PendingBetaLogin {
        var profile: AppleProfile
        let device: Device
        let account: AccountSession
        let expires: Date
    }
    private var pendingBetaLogin: PendingBetaLogin?
    private struct PendingNativeBetaLogin {
        let profile: AppleProfile
        let materials: NativeStoreLogin.Materials
        let expires: Date
    }
    private var pendingNativeBetaLogin: PendingNativeBetaLogin?
    private struct BetaAuthenticationDevice {
        let owner: String
        let hardware: Data
        let key: Data
        let device: Device
    }
    private var betaAuthenticationDevice: BetaAuthenticationDevice?
    private var betaClient: TestFlightClient?
    private var accountsReadable = true
    private var credentialsReadable = true
    @Published var region = UserDefaults.standard.string(forKey: "catalog-region-override") ?? "" {
        didSet { UserDefaults.standard.set(region, forKey: "catalog-region-override") }
    }

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPADecryptMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? (folder as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        do {
            credentials = try loadCredentials()
        } catch {
            credentialsReadable = false
            message = "无法读取本机的 FairPlay 凭据。请解锁设备后重新打开 App。"
        }
        do {
            accounts = try loadAccounts()
        } catch {
            accountsReadable = false
            message = "无法读取本机账户。请解锁设备后重新打开 App。"
        }
        if let data = try? Data(contentsOf: history), let saved = try? JSONDecoder().decode([LocalJob].self, from: data) {
            jobs = saved.map { job in
                let check = FairPlay.isCompleteIPA(path(for: job, clear: false))
                return job.recovered(originalIsComplete: check)
            }
            persist()
        }
    }

    private var history: URL { folder.appendingPathComponent("jobs.json") }
    private var accountsFile: URL { folder.appendingPathComponent("accounts-v2.json") }
    private var credentialsFile: URL { folder.appendingPathComponent("credentials-v2.json") }
    private var storeStorage: StoreSessionStorage { StoreSessionStorage(directory: folder) }

    var automaticCountry: String {
        Storefronts.country(for: activeProfile(beta: false)?.storefront) ?? Storefronts.deviceCountry
    }
    var country: String { region.isEmpty ? automaticCountry : region }

    func activeProfile(beta: Bool) -> AppleProfile? {
        let id = beta ? accounts.activeBeta : accounts.activeStore
        return (beta ? accounts.beta : accounts.store).first { $0.id == id }
    }

    private func readProtected<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func saveProtected<T: Encodable>(_ value: T, at url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private var passwordsFolder: URL {
        folder.appendingPathComponent("PrivatePasswords", isDirectory: true)
    }

    private var passwordsFile: URL {
        passwordsFolder.appendingPathComponent("passwords.json")
    }

    func savedPassword(for input: String) -> String? {
        guard let id = try? Self.signInID(input).lowercased() else { return nil }
        do {
            let saved = try readProtected([String: String].self, at: passwordsFile) ?? [:]
            if let password = saved[id] {
                return password.isEmpty ? nil : password
            }
            guard let data = Vault.read("apple-password/" + id),
                  let legacy = String(data: data, encoding: .utf8), !legacy.isEmpty else { return nil }
            try savePassword(legacy, for: id)
            return legacy
        } catch { return nil }
    }

    func savePassword(_ password: String, for input: String) throws {
        let id = try Self.signInID(input).lowercased()
        do {
            var saved = try readProtected([String: String].self, at: passwordsFile) ?? [:]
            // An empty marker prevents a deleted password from being reimported
            // from an older Keychain entry if signing permissions later change.
            saved[id] = password
            try FileManager.default.createDirectory(at: passwordsFolder, withIntermediateDirectories: true)
            var directory = passwordsFolder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try saveProtected(saved, at: passwordsFile)
            Vault.remove("apple-password/" + id)
            storeRecovery.reset(id)
        } catch {
            throw LabError(password.isEmpty
                           ? "无法删除已保存密码。请解锁设备后重试。"
                           : "无法保存密码。请确认设备已解锁且有可用存储。")
        }
    }

    func forgetPassword(for input: String) throws {
        try savePassword("", for: input)
    }

    private func loadAccounts() throws -> AccountBook {
        if let saved = try readProtected(AccountBook.self, at: accountsFile) { return saved }
        var book = AccountBook()
        let legacy = try storeStorage.loadState()
        if let account = storeIdentity(legacy), account.passwordToken?.isEmpty == false {
            let profile = AppleProfile(email: account.email ?? "原 App Store 账户", storefront: account.storeFront,
                                       hardware: try storeStorage.hardware(), state: legacy)
            book.store = [profile]
            book.activeStore = profile.id
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("beta.session").path),
           Vault.read("session-key") != nil {
            let profile = AppleProfile(email: "原 TestFlight 账户", hardware: Data(), legacyBeta: true)
            book.beta = [profile]
            book.activeBeta = profile.id
        }
        try saveProtected(book, at: accountsFile)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ipatool-state"))
        return book
    }

    private func storeIdentity(_ state: [String: Data]) -> StoreIdentity? {
        state["account"].flatMap { try? JSONDecoder().decode(StoreIdentity.self, from: $0) }
    }

    private func saveAccounts(_ updated: AccountBook) throws {
        guard accountsReadable else { throw LabError("请解锁设备后重新打开 App，再修改账户。") }
        do { try saveProtected(updated, at: accountsFile) }
        catch { throw storeStorageIssue("session", error: error) }
        accounts = updated
    }

    func switchAccount(_ id: UUID, beta: Bool) throws {
        guard action == nil && automaticStoreLoginStatus == nil else { throw LabError("请等待当前任务完成后再切换或退出账户。") }
        var updated = accounts
        if beta {
            guard updated.beta.contains(where: { $0.id == id }) else { return }
            updated.activeBeta = id
        } else {
            guard updated.store.contains(where: { $0.id == id }) else { return }
            updated.activeStore = id
        }
        try saveAccounts(updated)
        if beta { betaClient = nil }
    }

    private func loadCredentials() throws -> [FairPlayCredential] {
        if let saved = try readProtected([FairPlayCredential].self, at: credentialsFile) { return saved }
        let old = Vault.read("fairplay").flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? []
        guard !old.isEmpty else { return [] }
        let migrated = old.filter { $0.count == 16 }.map { FairPlayCredential(data: $0) }
        try saveProtected(migrated, at: credentialsFile)
        Vault.remove("fairplay")
        return migrated
    }

    func persist() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: history, options: [.atomic, .completeFileProtection]) }
    }
    private func set(_ id: UUID, _ state: LocalJob.State, _ note: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].note = note
        persist()
    }

    @discardableResult
    func addCredential(_ data: Data, owner: String?, origin: String = "文件导入", evidence: CredentialLicenseEvidence? = nil) throws -> UUID {
        guard data.count == 16 else { throw LabError("请选择恰好 16 字节的 credential.bin。") }
        return try saveCredential(data, owner: owner, origin: origin, evidence: evidence)
    }

    @discardableResult
    func addCredential(hex: String, owner: String?) throws -> UUID {
        var input = String(hex.filter { !$0.isWhitespace })
        if input.lowercased().hasPrefix("0x") { input.removeFirst(2) }
        let digits = Array(input.utf8)
        guard digits.count == 32, digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw LabError("请输入 32 位十六进制字符，可带 0x 前缀。")
        }
        var data = Data()
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else {
                throw LabError("无效的十六进制凭据。")
            }
            data.append(byte)
        }
        return try saveCredential(data, owner: owner, origin: "十六进制导入")
    }

    private func saveCredential(_ data: Data, owner: String?, origin: String, evidence: CredentialLicenseEvidence? = nil) throws -> UUID {
        if let index = credentials.firstIndex(where: { $0.owner == owner && $0.data == data }) {
            if let evidence, !(credentials[index].verifiedLicenses ?? []).contains(evidence) {
                var updated = credentials
                updated[index].verifiedLicenses = (updated[index].verifiedLicenses ?? []) + [evidence]
                try saveCredentials(updated)
            }
            return credentials[index].id
        }
        let record = FairPlayCredential(owner: owner, data: data, addedAt: Date(), origin: origin, verifiedLicenses: evidence.map { [$0] })
        try saveCredentials(credentials + [record])
        return record.id
    }

    @discardableResult
    func addEnrollmentModel(_ data: Data, owner: String?, origin: String, appName: String? = nil, verified: Bool? = nil) throws -> UUID {
        let format = try EnrollmentModelFormat(data)
        if let old = credentials.first(where: { $0.isEnrollment && $0.data == data }) { return old.id }
        var record = FairPlayCredential(owner: owner, data: data, label: appName.map { $0 + " · 本机模型" }, addedAt: Date(), origin: origin)
        record.kind = "mac-enrollment"; record.enrollmentSelector = format.selector
        record.sourceApp = appName; record.plaintextVerified = verified
        try saveCredentials(credentials + [record]); return record.id
    }

    func renameCredential(_ id: UUID, label: String) throws {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        var updated = credentials
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].label = name.isEmpty ? nil : String(name.prefix(120))
        try saveCredentials(updated)
    }

    func moveCredential(_ id: UUID, to owner: String?) throws {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        var updated = credentials
        if updated.contains(where: { $0.id != id && $0.owner == owner && $0.data == updated[index].data }) {
            updated.remove(at: index)
        } else {
            updated[index].owner = owner
        }
        try saveCredentials(updated)
    }

    func removeCredential(_ id: UUID) throws {
        try saveCredentials(credentials.filter { $0.id != id })
    }

    private func saveCredentials(_ updated: [FairPlayCredential]) throws {
        guard credentialsReadable else { throw LabError("请解锁设备后重新打开 App，再修改凭据。") }
        do { try saveProtected(updated, at: credentialsFile) }
        catch { throw LabError("无法保存 FairPlay 凭据。请检查设备是否已解锁及剩余存储。") }
        credentials = updated
    }

    func getCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard codeRequest == nil else { continuation.resume(throwing: LabError("已有验证码请求。")); return }
            pickingBetaPhone = false
            codeDeliveryBusy = false
            if !storeCodeDelivery { resetBetaDelivery() }
            codeRequest = continuation
            askingCode = true
        }
    }
    func finishCode(_ code: String?) {
        let continuation = codeRequest
        codeRequest = nil
        askingCode = false
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveryID = nil
        let pendingPhone = phoneRequest
        phoneRequest = nil
        pendingPhone?.resume(throwing: CancellationError())
        codePhones = []
        pickingBetaPhone = false
        betaCanUseTrustedDevice = false
        codeDeliveryBusy = false
        codeDeliveryDiagnostic = nil
        codeDeliveryMessage = nil
        codeDeliveryFailed = false
        nextCodeRequest = .distantPast
        if let code { continuation?.resume(returning: code) }
        else { continuation?.resume(throwing: CancellationError()) }
    }

    private enum CodeDeliveryResult: Error { case requested }

    private static let macOSVersion = "26.6"
    private static let macOSBuild = "25G72"
    private static let macNetworkAgent = "CFNetwork/3860.200.71 Darwin/25.6.0"
    private static let testFlightMacModel = "Mac15,8"
    private static let testFlightMacVariants = "MacFamily20,1 iPad14,5"
    private static let testFlightMacOSVersion = "26.4.1"
    private static let testFlightMacOSBuild = "25E253"
    private static let testFlightMacNetworkAgent = "CFNetwork/3860.500.112 Darwin/25.4.0"

    // GrandSlam rejects the SDK's default client at the first SRP request.
    // Keep the same modern device profile for TestFlight and SMS.
    static func makeAppleAuthDevice(encryptionKey: Data? = nil) throws -> Device {
        try Device(platform: .mac, macOSVersion: macOSVersion, macOSBuild: macOSBuild,
                   userAgent: "akd/1.0 \(macNetworkAgent)", encryptionKey: encryptionKey)
    }

    private static func authIssue(_ phase: String, error: Error) -> StoreIssue {
        if let issue = error as? StoreIssue { return issue }
        let description = error.localizedDescription
        let detail = description.lowercased()
        let code = description.range(of: #"HTTP [1-5][0-9]{2}|code -?[0-9]{1,7}"#, options: .regularExpression)
            .map { " " + description[$0] } ?? ""
        let serverCode = phase == "testflight-session"
            ? description.range(of: #" Apple error -?[0-9]{1,7}(?![0-9])"#, options: .regularExpression)
                .map { String(description[$0]) } ?? ""
            : ""
        let stage: String
        if phase == "testflight-session", detail.contains("testflight session creation rejected") {
            stage = code == " HTTP 401" || code == " HTTP 403" ? "exchange-rejected" : "exchange"
        } else if phase == "testflight-session", detail.contains("testflight session response format") {
            stage = "response-format"
        } else if phase == "testflight-session", detail.contains("testflight session response missing credentials") {
            stage = "response-missing-session"
        } else if phase == "testflight-session", error is URLError {
            stage = "transport"
        } else if phase == "testflight-store",
           let marker = detail.range(of: #"(?<=mac store stage )[a-z-]+(?=:)"#, options: .regularExpression) {
            stage = String(detail[marker])
        }
        else if detail.contains("provision") { stage = "device-registration" }
        else if detail.contains("sms verification configuration") { stage = "trusted-phones" }
        else if detail.contains("request sms") { stage = "sms-send" }
        else if detail.contains("sms code") || detail.contains("2fa code") { stage = "code-verification" }
        else if detail.contains("grandslam init") { stage = "srp-init" }
        else if detail.contains("grandslam complete") { stage = "srp-complete" }
        else if detail.contains("mac store response format") { stage = "response-format" }
        else if detail.contains("mac store response rejected") { stage = "response-rejected" }
        else if detail.contains("mac store response missing account id") { stage = "account-id-missing" }
        else if detail.contains("mac store response account mismatch") { stage = "account-id-mismatch" }
        else if detail.contains("mac store response missing session token") { stage = "session-token-missing" }
        else if detail.contains("store session has no unexpired root apple cookies") { stage = "store-cookies-missing" }
        else if detail.contains("mac pet has expired") { stage = "proof-expired" }
        else if detail.contains("mac store authentication") { stage = "authenticate" }
        else if detail.contains("mac store redirect") { stage = "redirect" }
        else { stage = phase }
        let credentialIssue = (stage == "srp-init" || stage == "srp-complete") &&
            [" code -20970", " code -20101", " code -22406"].contains(code)
        let proofScheme: String
        if detail.contains("grandslam complete (s2k_fo)") { proofScheme = " [s2k_fo]" }
        else if detail.contains("grandslam complete (s2k)") { proofScheme = " [s2k]" }
        else { proofScheme = "" }
        let message: String
        if stage == "srp-complete" && code == " code -22406" {
            message = "Apple 拒绝了 App 提交的登录证明。若官网能登录，请复制下方诊断码。"
        } else if credentialIssue {
            message = "Apple 未接受这次账号验证。请核对完整邮箱或登录手机号，以及 Apple 账户密码。"
        } else if stage == "sms-send" && (code == " HTTP 423" || code == " HTTP 429") {
            message = "Apple 暂不允许发送短信验证码。可改用受信任设备，或稍后再请求短信。"
        } else if stage == "sms-send" && code.hasPrefix(" HTTP 5") {
            message = "Apple 的短信发送请求返回错误。可改用受信任设备，或稍后再试。"
        } else if detail.contains("http 503") { message = "Apple 暂时拒绝了此登录请求（HTTP 503）。请稍后重试。" }
        else if detail.contains("http 429") { message = "Apple 暂时限制请求频率，请稍后重试。" }
        else if stage == "trusted-phones" && detail.contains("http 202") {
            message = phase == "testflight-auth"
                ? "Apple 暂未提供受信任手机号。可关闭「使用短信验证码」，用受信任设备验证。"
                : "Apple 暂未提供受信任手机号。可改用受信任设备验证。"
        }
        else if stage == "trusted-phones" && detail.contains("http 403") {
            message = "Apple 拒绝读取受信任手机号。你仍可使用受信任设备上的验证码。"
        } else if detail.contains("no trusted sms") {
            message = "Apple 没有返回可用的受信任手机号。"
        } else if stage == "code-verification" {
            message = "Apple 未通过验证码校验，请重新登录并使用新验证码。"
        } else if stage == "session-encode" || stage == "session-validation" {
            message = "Apple 已接受账户验证，但 App 无法读取返回的 Store 会话。请复制下方诊断码。"
        } else if stage == "store-cookies-missing" {
            message = "Apple 未返回建立 TestFlight 会话所需的 Store Cookie。"
        } else if stage == "exchange-rejected" {
            message = serverCode == " Apple error 102"
                ? "Apple 账户验证已完成，但 TestFlight 未接受 IPA 解密 提交的 Store 凭据（错误 102）。此错误不能用于判断账户密码是否正确。"
                : "TestFlight 拒绝了本次 Store 凭据。请重新验证 Apple 账户。"
        } else if phase == "testflight-session", stage == "transport" {
            message = "连接 TestFlight 时网络请求失败，可以重试建立会话。"
        } else if phase == "testflight-session", stage == "response-format" || stage == "response-missing-session" {
            message = "TestFlight 返回了响应，但 App 无法从中读取会话。"
        } else if phase == "testflight-store" {
            message = "Apple 账户验证已完成，但未能建立 TestFlight 所需的 Store 会话。"
        } else if phase == "testflight-session" {
            message = "已登录 Apple，但未能建立 TestFlight 会话。"
        } else {
            message = "Apple 未完成认证请求。请重试或查看下方诊断码。"
        }
        return StoreIssue(message: message, diagnostic: phase + "/" + stage + code + serverCode + proofScheme,
                          requiresAccountAction: credentialIssue)
    }

    func selectBetaPhone(_ id: Int64) {
        guard pickingBetaPhone, let pending = phoneRequest else { return }
        if id == 0 {
            guard betaCanUseTrustedDevice else { return }
        } else {
            guard Date() >= nextCodeRequest, codePhones.contains(where: { $0.id == id }) else { return }
        }
        phoneRequest = nil
        resetBetaDelivery()
        codeDeliveryBusy = true
        pending.resume(returning: id)
    }

    private func resetBetaDelivery() {
        betaCanUseTrustedDevice = false
        codeDeliveryMessage = nil
        codeDeliveryDiagnostic = nil
        codeDeliveryFailed = false
        nextCodeRequest = .distantPast
    }

    private func chooseBetaPhone(_ phones: [TrustedPhoneNumber]) async throws -> Int64 {
        guard !Task.isCancelled else { throw CancellationError() }
        resetBetaDelivery()
        if let failure = phones.first, let status = failure.smsDeliveryStatus {
            betaCanUseTrustedDevice = failure.allowsTrustedDevice == true
            codeDeliveryFailed = true
            codeDeliveryDiagnostic = "testflight-auth/sms-send HTTP \(status)"
            let limited = status == 423 || status == 429
            codeDeliveryMessage = limited
                ? "Apple 暂时限制发送短信。稍后可以重试或选择其他号码。"
                : "Apple 的短信发送请求返回错误。可以重试或选择其他号码。"
            nextCodeRequest = Date().addingTimeInterval(limited ? 60 : 10)
        }
        return try await choosePhone(phones, beta: true)
    }

    func requestStoreCode(method: VerificationMethod, phoneID: Int64 = 0) {
        guard askingCode, storeCodeDelivery, Date() >= nextCodeRequest,
              let credentials = deliveryCredentials else { return }
        if method == .sms && phoneID > 0 {
            guard codePhones.contains(where: { $0.id == phoneID }) else { return }
            if let pending = phoneRequest {
                phoneRequest = nil
                codeDeliveryBusy = true
                codeDeliveryMessage = nil
                pending.resume(returning: phoneID)
                return
            }
        }
        guard !codeDeliveryBusy else { return }
        deliveryTask?.cancel()
        let pending = phoneRequest
        phoneRequest = nil
        pending?.resume(throwing: CancellationError())

        let id = UUID()
        deliveryID = id
        codeDeliveryBusy = true
        codeDeliveryMessage = nil
        codeDeliveryDiagnostic = nil
        codeDeliveryFailed = false
        deliveryTask = Task {
            do {
                if method == .trustedDevice, let storeResend {
                    let reply = try await storeResend()
                    guard deliveryID == id else { return }
                    if reply.reason == "code" {
                        finishCodeDelivery(id, message: "已重新发起 App Store 验证，请查看受信任设备。", failed: false)
                    } else {
                        try acceptStore(reply)
                        storeResendReply = reply
                        finishCode("")
                    }
                    return
                }
                let device = try deliveryDevice ?? Self.makeAppleAuthDevice()
                deliveryDevice = device
                let verification = Verification(method: method, phoneNumberID: phoneID, selectPhone: { [weak self] phones in
                    guard let self else { throw CancellationError() }
                    return try await self.chooseStorePhone(phones, for: id)
                }) {
                    // The Store bridge submits the code with the pending ipatool login.
                    throw CodeDeliveryResult.requested
                }
                _ = try await device.login(email: credentials.email, password: credentials.password,
                                           verification: verification)
                finishCodeDelivery(id, message: "Apple 未要求发送验证码。可以输入已有验证码，或在受信任设备上获取。", failed: true)
            } catch CodeDeliveryResult.requested {
                let message = method == .sms ? "已向所选号码请求发送短信。" : "已请求验证，请查看受信任设备。"
                finishCodeDelivery(id, message: message, failed: false)
            } catch is CancellationError {
                finishCodeDelivery(id, message: nil, failed: false)
            } catch {
                guard deliveryID == id else { return }
                let issue = Self.authIssue(method == .sms ? "sms" : "store-resend", error: error)
                codeDeliveryDiagnostic = issue.diagnostic
                finishCodeDelivery(id, message: issue.message, failed: true)
                if let diagnostic = issue.diagnostic,
                   diagnostic.contains("HTTP 429") || diagnostic.contains("sms-send HTTP 423") {
                    nextCodeRequest = Date().addingTimeInterval(60)
                }
            }
        }
    }

    private func chooseStorePhone(_ phones: [TrustedPhoneNumber], for id: UUID) async throws -> Int64 {
        guard deliveryID == id, askingCode, !Task.isCancelled else { throw CancellationError() }
        return try await choosePhone(phones, beta: false)
    }

    private func choosePhone(_ phones: [TrustedPhoneNumber], beta: Bool) async throws -> Int64 {
        var seen = Set<Int64>()
        codePhones = phones.filter { $0.id > 0 && seen.insert($0.id).inserted }
        guard !codePhones.isEmpty else { throw LabError("No trusted SMS phone numbers") }
        return try await withCheckedThrowingContinuation { continuation in
            phoneRequest = continuation
            pickingBetaPhone = beta
            if beta { askingCode = true }
            codeDeliveryBusy = false
        }
    }

    private func finishCodeDelivery(_ id: UUID, message: String?, failed: Bool) {
        guard deliveryID == id else { return }
        codeDeliveryBusy = false
        codeDeliveryMessage = message
        codeDeliveryFailed = failed
        if !failed && message != nil { nextCodeRequest = Date().addingTimeInterval(30) }
    }

    static func signInID(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            let labels = parts.last?.split(separator: ".", omittingEmptySubsequences: false) ?? []
            guard parts.count == 2, !parts[0].isEmpty, labels.count >= 2,
                  labels.allSatisfy({ !$0.isEmpty }), !value.contains(where: \.isWhitespace) else {
                throw LabError("请输入完整的 Apple 账户邮箱，例如 name@example.com。")
            }
            return value
        }
        let phone = String(value.filter { !$0.isWhitespace && !"-()".contains($0) })
        let digits = phone.dropFirst()
        guard phone.hasPrefix("+"), (7...15).contains(digits.count),
              digits.first != "0", digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw LabError("请输入 Apple 账户邮箱或带国家区号的登录手机号，例如 +86。")
        }
        return phone
    }

    func login(email input: String, password: String, beta: Bool, initialCode: String = "", betaSMS: Bool = false, nativeBeta: Bool = false) async throws {
        guard accountsReadable else { throw LabError("请解锁设备后重新打开 App，再登录。") }
        let email = try Self.signInID(input)
        guard !password.isEmpty else { throw LabError("请输入 Apple 账户密码。") }
        if beta && nativeBeta {
            try await loginNativeBeta(email: email, password: password, code: initialCode)
            return
        }
        if beta {
            pendingNativeBetaLogin = nil
            pendingBetaLogin = nil
            defer { if askingCode { finishCode(nil) } }
            let verification = Verification(method: betaSMS ? .sms : .automatic,
                                            recoverSMSDelivery: true, selectPhone: { [weak self] phones in
                guard let self else { throw CancellationError() }
                return try await self.chooseBetaPhone(phones)
            }) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.getCode()
            }
            let identity = try testFlightAuthenticationDevice(for: email)
            let profile = AppleProfile(email: email, hardware: identity.hardware,
                                       state: ["session-key": identity.key])
            let device = identity.device
            let account: AccountSession
            do { account = try await device.login(email: email, password: password, verification: verification) }
            catch is CancellationError { throw CancellationError() }
            catch { throw Self.authIssue("testflight-auth", error: error) }
            let continuation = PendingBetaLogin(profile: profile, device: device, account: account,
                                                expires: Date().addingTimeInterval(240))
            pendingBetaLogin = continuation
            try await finishBetaLogin(continuation)
        } else {
            storeCodeDelivery = true
            deliveryCredentials = (email, password)
            defer {
                storeCodeDelivery = false
                deliveryCredentials = nil
                deliveryDevice = nil
                storeResend = nil
                storeResendReply = nil
            }
            var profile: AppleProfile
            if let saved = accounts.store.first(where: { $0.owner == email.lowercased() }) {
                profile = saved
            } else {
                profile = AppleProfile(email: email, hardware: try Vault.randomBytes(length: 6))
            }
            storeResend = { [weak self, profile] in
                guard let self else { throw CancellationError() }
                return try await self.requestStore("login", profile: profile, email: email, password: password)
            }
            var reply = try await requestStore("login", profile: profile, email: email, password: password, code: initialCode)
            if reply.reason == "code" && initialCode.isEmpty {
                do {
                    let code = try await getCode()
                    if let result = storeResendReply {
                        reply = result
                    } else {
                        reply = try await requestStore("login", profile: profile, email: email, password: password, code: code)
                    }
                } catch {
                    _ = try? await requestStore("cancel-login", profile: profile)
                    throw error
                }
            }
            try acceptStore(reply)
            guard let state = reply.state, let identity = storeIdentity(state), identity.passwordToken?.isEmpty == false else {
                throw LabError("Apple 未返回有效会话。")
            }
            profile.state = state
            profile.email = identity.email ?? email
            profile.storefront = identity.storeFront
            profile.needsReauth = false
            var updated = accounts
            let replaced = updated.store.filter {
                $0.id == profile.id || $0.owner == profile.owner ||
                    (identity.directoryServicesIdentifier != nil &&
                        storeIdentity($0.state)?.directoryServicesIdentifier == identity.directoryServicesIdentifier)
            }
            updated.store.removeAll { candidate in replaced.contains { $0.id == candidate.id } }
            updated.store.append(profile)
            updated.activeStore = profile.id
            try saveAccounts(updated)
            storeRecovery.reset(profile.owner)
            for old in replaced where old.hardware != profile.hardware {
                _ = try? await requestStore("signout", profile: old)
            }
        }
    }

    func retryBetaSession(email input: String) async throws {
        let email = try Self.signInID(input)
        if let native = pendingNativeBetaLogin, native.profile.owner == email.lowercased(), native.expires > Date() {
            try await finishNativeBetaLogin(native)
            return
        }
        guard let pendingBetaLogin, pendingBetaLogin.profile.owner == email.lowercased(),
              pendingBetaLogin.expires > Date() else {
            self.pendingBetaLogin = nil
            throw LabError("Apple 账户验证已过期，请重新登录。")
        }
        try await finishBetaLogin(pendingBetaLogin)
    }

    private func loginNativeBeta(email: String, password: String, code: String) async throws {
        pendingBetaLogin = nil
        pendingNativeBetaLogin = nil
        let runtime = try NativeStoreLogin(directory: NativeStoreLogin.ownerDirectory(email, base: folder))
        defer { runtime.close(); if askingCode { finishCode(nil) } }
        let hardware = try accounts.beta.first(where: { $0.owner == email.lowercased() && $0.hardware.count == 20 })?.hardware
            ?? Vault.randomBytes(length: 20)
        let key = try Vault.randomBytes(length: 32)
        let materials = try await runtime.login(email: email, password: password, code: code) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.getCode()
        }
        var profile = AppleProfile(email: email, hardware: hardware, state: ["session-key": key])
        profile.storefront = materials.storefront
        let pending = PendingNativeBetaLogin(profile: profile, materials: materials, expires: Date().addingTimeInterval(240))
        pendingNativeBetaLogin = pending
        try await finishNativeBetaLogin(pending)
    }

    private func finishNativeBetaLogin(_ pending: PendingNativeBetaLogin) async throws {
        guard let key = pending.profile.state["session-key"] else { throw LabError("TestFlight 会话密钥缺失。") }
        do {
            let session = try await NativeStoreLogin.exchange(pending.materials, hardware: pending.profile.hardware)
            let client = try await TestFlightClient.deserialize(session)
            try await commitBetaClient(client, profile: pending.profile, key: key)
            pendingNativeBetaLogin = nil
        } catch let issue as StoreIssue {
            if issue.diagnostic?.hasPrefix("testflight-session/exchange-rejected") == true { pendingNativeBetaLogin = nil }
            throw issue
        }
    }

    private func testFlightAuthenticationDevice(for email: String) throws -> BetaAuthenticationDevice {
        let owner = email.lowercased()
        if let saved = betaAuthenticationDevice, saved.owner == owner { return saved }
        let savedHardware = accounts.beta.first { $0.owner == owner && $0.hardware.count == 20 }?.hardware
        let hardware = try savedHardware ?? Vault.randomBytes(length: 20)
        let key = try Vault.randomBytes(length: 32)
        let device = try Device(platform: .mac, model: Self.testFlightMacModel,
                                macOSVersion: Self.testFlightMacOSVersion, macOSBuild: Self.testFlightMacOSBuild,
                                userAgent: "akd/1.0 \(Self.testFlightMacNetworkAgent)", encryptionKey: key)
        let identity = BetaAuthenticationDevice(owner: owner, hardware: hardware, key: key, device: device)
        betaAuthenticationDevice = identity
        return identity
    }

    private func finishBetaLogin(_ pending: PendingBetaLogin) async throws {
        var profile = pending.profile
        let device = pending.device
        let account = pending.account
        let email = profile.email
        guard let key = profile.state["session-key"] else { throw LabError("TestFlight 会话密钥缺失。") }
        let store: StoreSession
        do { store = try await device.loginStoreWithPET(email: email, account: account) }
        catch { throw Self.authIssue("testflight-store", error: error) }
        profile.storefront = store.storefront
        let client: TestFlightClient
        do {
            let headers = Self.testFlightHeaders(device: device)
            client = try await TestFlightClient.fromStoreSession(store, hardware20: profile.hardware, macHeaders: headers)
        } catch {
            let issue = Self.authIssue("testflight-session", error: error)
            if issue.diagnostic?.hasPrefix("testflight-session/exchange-rejected") == true {
                pendingBetaLogin = nil
            }
            if let diagnostic = issue.diagnostic, diagnostic.hasSuffix(" Apple error 102") {
                throw StoreIssue(message: issue.message,
                                 diagnostic: diagnostic + "\n" + Self.testFlightCookieEvidence(store),
                                 requiresAccountAction: issue.requiresAccountAction)
            }
            throw issue
        }
        try await commitBetaClient(client, profile: profile, key: key)
        pendingBetaLogin = nil
    }

    private func commitBetaClient(_ client: TestFlightClient, profile: AppleProfile, key: Data) async throws {
        let data = try await client.serialize(encryptionKey: key)
        let previous = accounts.beta.first { $0.owner == profile.owner }
        let destination = betaSessionFile(profile)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        do {
            var updated = accounts
            updated.beta.removeAll { $0.owner == profile.owner }
            updated.beta.append(profile)
            updated.activeBeta = profile.id
            try saveAccounts(updated)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if let previous { try? FileManager.default.removeItem(at: betaSessionFile(previous)) }
        betaClient = client
    }

    // Report only presence and scope for the documented Store authentication cookie families.
    private static func testFlightCookieEvidence(_ store: StoreSession, now: Date = Date()) -> String {
        guard let plist = try? PropertyListSerialization.propertyList(from: store.plist, format: nil),
              let state = plist as? [String: Any], let cookies = state["cookies"] as? [[String: Any]] else {
            return "store-cookie-profile unavailable"
        }
        let families = ["mz_at0", "mz_at_ssl"]
        let matchingScope = families.map { family in
            let accountName = family + "-" + store.accountID
            let matching = cookies.filter { cookie in
                guard let name = cookie["name"] as? String else { return false }
                return name == family || name == accountName
            }
            if matching.contains(where: { cookie in
                guard let value = cookie["value"] as? String, !value.isEmpty,
                      let expires = cookie["expires"] as? Int64,
                      expires == 0 || Double(expires) > now.timeIntervalSince1970 else { return false }
                return cookie["domain"] as? String == "apple.com" && cookie["path"] as? String == "/"
                    && cookie["host_only"] as? Bool == false
            }) {
                return "\(family)=root"
            }
            if !matching.isEmpty { return "\(family)=not-exported" }
            let otherAccount = cookies.contains { cookie in
                let prefix = family + "-"
                guard let name = cookie["name"] as? String else { return false }
                guard name.hasPrefix(prefix) else { return false }
                let suffix = name.dropFirst(prefix.count)
                return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
            }
            return "\(family)=\(otherAccount ? "other-account" : "absent")"
        }
        return "store-cookie-profile " + matchingScope.joined(separator: " ")
    }

    private static func testFlightHeaders(device: Device) -> [String: String] {
        let model = device.info.model ?? testFlightMacModel
        let os = device.info.osVersion ?? testFlightMacOSVersion
        let build = device.info.osBuild ?? testFlightMacOSBuild
        // The macOS TestFlight exchange uses the Oasis user agent.
        let agent = "Oasis/4.1.0 OasisBuild/587.3 (Macintosh; OS X \(os); \(build)) "
            + "AppleWebKit/1624.1.16.11.4 AMS/1 (dt:1) TSE/0"
        return [
            "User-Agent": agent,
            "X-Apple-Device-Model": model,
            "X-Apple-TA-Device": testFlightMacVariants,
            "X-Apple-TestFlight-iOS": "1",
            "X-Apple-Rosetta-Available": "0"
        ]
    }

    private func betaSessionFile(_ profile: AppleProfile) -> URL {
        folder.appendingPathComponent(profile.legacyBeta ? "beta.session" : "beta-\(profile.id.uuidString).session")
    }

    func signOut(beta: Bool) throws {
        guard action == nil && automaticStoreLoginStatus == nil else { throw LabError("请等待当前任务完成后再切换或退出账户。") }
        guard let profile = activeProfile(beta: beta) else { return }
        var updated = accounts
        if beta {
            updated.beta.removeAll { $0.id == profile.id }
            updated.activeBeta = updated.beta.first?.id
        } else {
            updated.store.removeAll { $0.id == profile.id }
            updated.activeStore = updated.store.first?.id
        }
        try saveAccounts(updated)
        if beta {
            betaClient = nil
            if betaAuthenticationDevice?.owner == profile.owner { betaAuthenticationDevice = nil }
            try? FileManager.default.removeItem(at: betaSessionFile(profile))
        } else {
            Task { _ = try? await requestStore("signout", profile: profile) }
        }
    }

    private func requestStore(_ operation: String, profile: AppleProfile, email: String = "", password: String = "",
                              code: String = "", query: String = "", bundle: String = "", id: UInt64 = 0,
                              path: String = "", version: String = "") async throws -> StoreReply {
        let device = profile.hardware.map { String(format: "%02X", $0) }.joined(separator: ":")
        let request = StoreRequest(operation: operation, device: device, email: email,
                                   password: password, code: code, query: query, path: path,
                                   bundle: bundle, version: version, id: id, state: profile.state)
        return try await Task.detached(priority: .userInitiated) { try request.perform() }.value
    }

    private func sendStore(_ operation: String, query: String = "", bundle: String = "", id: UInt64 = 0,
                           path: String = "", version: String = "") async throws -> StoreReply {
        guard let original = activeProfile(beta: false) else { throw LabError("请先登录 App Store。") }
        let owner = original.owner
        return try await storeRecovery.perform(owner: owner, initiallyExpired: original.needsReauth == true,
            authenticate: { [weak self] in
                guard let self else { throw CancellationError() }
                guard self.automaticStoreLogin else { throw StoreRecoveryFailure.disabled }
                guard self.activeProfile(beta: false)?.owner == owner else { throw StoreRecoveryFailure.accountChanged }
                guard let password = self.savedPassword(for: original.email) else { throw StoreRecoveryFailure.passwordUnavailable }
                self.automaticStoreLoginStatus = "正在自动重新登录 App Store…"
                defer { self.automaticStoreLoginStatus = nil }
                do { try await self.login(email: original.email, password: password, beta: false) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if let issue = error as? StoreIssue {
                        throw StoreIssue(message: "自动登录未完成：" + issue.message + " 请在 Apple 账户中重新登录。" + (issue.diagnostic.map { "\n\n" + $0 } ?? ""), diagnostic: issue.diagnostic, requiresAccountAction: issue.requiresAccountAction)
                    }
                    throw LabError("自动登录未完成。请在 Apple 账户中手动重新登录后重试。")
                }
            }, retryAuthentication: { error in
                guard let issue = error as? StoreIssue else { return false }
                return StoreAuthenticationRetryPolicy.permits(diagnostic: issue.diagnostic, requiresAccountAction: issue.requiresAccountAction)
            }, request: { [weak self] in
                guard let self else { throw CancellationError() }
                guard let profile = self.activeProfile(beta: false), profile.owner == owner else { throw StoreRecoveryFailure.accountChanged }
                return try await self.sendStoreOnce(operation, profile: profile, query: query, bundle: bundle, id: id, path: path, version: version)
            }, isExpired: { $0.error == true && $0.reason == "expired" })
    }

    private func sendStoreOnce(_ operation: String, profile: AppleProfile, query: String, bundle: String, id: UInt64,
                               path: String, version: String) async throws -> StoreReply {
        let response = try await requestStore(operation, profile: profile, query: query, bundle: bundle,
                                              id: id, path: path, version: version)
        if let index = accounts.store.firstIndex(where: { $0.id == profile.id && $0.state == profile.state }),
           response.reason == "expired" || (response.state.map { $0 != profile.state } ?? false) {
            var updated = accounts
            if let state = response.state { updated.store[index].state = state }
            if response.reason == "expired" { updated.store[index].needsReauth = true; accounts = updated }
            try saveAccounts(updated)
        }
        return response
    }

    private func storeStorageIssue(_ operation: String, error: Error) -> StoreIssue {
        StoreIssue(message: "无法保存 Apple 账户数据。请解锁设备并检查可用存储。",
                   diagnostic: "store-storage/\(operation) \((error as NSError).code)",
                   requiresAccountAction: false)
    }

    private func acceptStore(_ response: StoreReply) throws {
        guard response.error == true else { return }
        let message: String
        switch response.reason {
        case "code": message = "Apple 要求双重认证。请使用新收到的 6 位验证码。"
        case "license": message = "当前账户没有此 App 的授权。免费 App 可先在搜索结果菜单选择「获取免费授权」。"
        case "license-exists": message = "当前账户已经拥有此 App，可以直接尝试下载。"
        case "license-conflict": message = "Apple 返回了该 App 的授权冲突。请选择其他可用版本，或检查账户的购买记录。"
        case "device-verification": message = "Apple 未通过此次下载的设备验证（1008）。"
        case "expired": message = "App Store 会话已失效，请重新登录。"
        case "credentials": message = "Apple 返回了账户凭据不通过的错误。请核对账号或密码。"
        case "disabled": message = "Apple 返回账户已停用。请在 Apple 账户页面检查状态。"
        case "account-action": message = "Apple 要求完成账户操作。请先在 Apple 账户或 App Store 中处理提示。"
        case "verification": message = "Apple 没有完成验证码校验。请获取新验证码后重试。"
        case "provisioning":
            switch response.diagnostic?.split(separator: " ").first {
            case "login/provisioning-assets": message = "无法准备首次登录所需的 Apple 组件。请检查手机的可用存储和网络，再重试。"
            case "login/provisioning-runtime": message = "Apple 登录组件无法在本机启动。"
            case "login/provisioning-store": message = "Apple 未完成 App Store 的设备注册。"
            default: message = "Apple 未完成登录所需的设备注册。"
            }
        case "runtime":
            if response.diagnostic == "login/unicorn-executable-memory" {
                message = "macOS 未允许设备证明组件执行。请提供诊断码及系统版本以便排查。"
            } else {
                message = "设备证明运行库无法加载或执行。请提供下方诊断码及 macOS 版本。"
            }
        case "endpoint": message = "Apple 登录接口未返回可用会话。"
        case "transport": message = "连接 Apple 登录服务失败。请检查网络后重试。"
        case "login": message = "App Store 登录没有完成。"
        default: message = "ipatool 请求失败。请检查 Apple 账户授权、网络和可用存储。"
        }
        throw StoreIssue(message: message, diagnostic: response.diagnostic,
                         requiresAccountAction: ["disabled", "account-action"].contains(response.reason ?? ""))
    }

    func catalog(_ term: String) async throws -> [AppResult] {
        try await AppCatalog.search(term, country: country)
    }

    private func testFlight() async throws -> TestFlightClient {
        if let betaClient { return betaClient }
        guard let profile = activeProfile(beta: true),
              let key = profile.legacyBeta ? Vault.read("session-key") : profile.state["session-key"] else {
            throw LabError("请先登录 TestFlight。")
        }
        let client = try await TestFlightClient.load(from: betaSessionFile(profile), encryptionKey: key)
        if activeProfile(beta: true)?.id == profile.id { betaClient = client }
        return client
    }

    func betaCatalog() async throws -> [Beta] {
        do {
            let data = try await testFlight().catalog()
            return try Beta.catalog(data)
        } catch {
            if let error = error as? AppleAuthError {
                throw BetaCatalogFailure.provider(message: error.message, code: error.code)
            }
            if let error = error as? URLError { throw BetaCatalogFailure.network(error.code.rawValue) }
            if error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 3840 {
                throw BetaCatalogFailure.invalidResponse
            }
            throw error
        }
    }

    func artifact(_ job: LocalJob, clear: Bool) -> URL? {
        if clear && job.state != .ready { return nil }
        if !clear && job.originalComplete == false { return nil }
        let file = path(for: job, clear: clear)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func path(for job: LocalJob, clear: Bool) -> URL {
        let safe = String(job.name.prefix(80).map { "/\\:".contains($0) || $0.isNewline ? "_" : $0 })
        return jobFolder(job)
            .appendingPathComponent((safe.isEmpty ? "App" : safe) + (clear ? "-decrypted.ipa" : ".ipa"))
    }

    private func jobFolder(_ job: LocalJob) -> URL {
        folder.appendingPathComponent(job.id.uuidString, isDirectory: true)
    }

    private func removeJobFiles(_ job: LocalJob) throws {
        do { try FileManager.default.removeItem(at: jobFolder(job)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    func removeJob(_ job: LocalJob) throws {
        guard action == nil else { throw LabError("请等当前任务完成后再删除。") }
        do {
            try removeJobFiles(job)
            let remaining = jobs.filter { $0.id != job.id }
            try saveProtected(remaining, at: history)
            jobs = remaining
        } catch {
            throw LabError("无法删除此记录。请解锁设备后重试。")
        }
    }

    private func create(_ name: String, source: Flow, state: LocalJob.State, version: String? = nil,
                        storeApp: AppResult? = nil, betaBundle: String? = nil,
                        replacing previous: LocalJob? = nil) throws -> LocalJob {
        let profile = source == .local ? nil : activeProfile(beta: source == .beta)
        let job = LocalJob(id: previous?.id ?? UUID(), name: name, source: source.rawValue, state: state,
                           credentialOwner: profile?.owner, version: version, storeApp: storeApp, betaBundle: betaBundle, originalComplete: false)
        if let previous {
            if FairPlay.isCompleteIPA(path(for: previous, clear: false)) {
                if let index = jobs.firstIndex(where: { $0.id == previous.id }) { jobs[index].originalComplete = true; persist() }
                throw LabError("完整原包已保留，请使用处理记录中的解密操作，无需重新下载。")
            }
            guard previous.state == .failed, artifact(previous, clear: false) == nil,
                  artifact(previous, clear: true) == nil,
                  jobs.contains(where: { $0.id == previous.id && $0.state == .failed }) else {
                throw LabError("此记录已经改变。请返回处理记录查看。")
            }
            try removeJobFiles(previous)
        }
        try FileManager.default.createDirectory(at: jobFolder(job), withIntermediateDirectories: true)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        persist()
        return job
    }

    func acquire(_ app: AppResult) async throws {
        guard activeProfile(beta: false) != nil else { throw LabError("请先登录 App Store。") }
        try acceptStore(try await sendStore("acquire", id: app.id))
    }

    func versions(for app: AppResult) async throws -> StoreVersionList {
        let reply = try await sendStore("versions", bundle: app.bundleId, id: app.id)
        try acceptStore(reply)
        var seen = Set<String>()
        let ids = ([reply.latest].compactMap { $0 } + Array((reply.versions ?? []).reversed()))
            .filter { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && seen.insert($0).inserted }
        return StoreVersionList(ids: ids, latest: reply.latest)
    }

    func versionName(_ version: String, for app: AppResult) async throws -> String? {
        let reply = try await sendStore("version-info", bundle: app.bundleId, id: app.id, version: version)
        try acceptStore(reply)
        return reply.displayVersion
    }

    @discardableResult func download(_ app: AppResult, version: String? = nil, replacing previous: LocalJob? = nil,
                                    automaticallyDecrypt: Bool = true) async throws -> LocalJob {
        guard activeProfile(beta: false) != nil else { throw LabError("请先登录 App Store。") }
        let job = try create(app.trackName, source: .store, state: .downloading, version: version,
                             storeApp: app, replacing: previous)
        let tracker = trackDownload(job.id, beta: false)
        defer { stopTracking(job.id, task: tracker) }
        do {
            try acceptStore(try await sendStore("download", query: app.trackName, bundle: app.bundleId,
                                               id: app.id, path: path(for: job, clear: false).path, version: version ?? ""))
            stopTracking(job.id, task: tracker)
            try await received(job, automaticallyDecrypt: automaticallyDecrypt)
            return jobs.first(where: { $0.id == job.id }) ?? job
        } catch {
            set(job.id, .failed, friendly(error))
            throw error
        }
    }

    @discardableResult func downloadBeta(_ title: String, bundle: String, replacing previous: LocalJob? = nil,
                                        automaticallyDecrypt: Bool = true) async throws -> LocalJob {
        guard LocalJob.isBundleID(bundle) else {
            throw LabError("请输入有效的 Bundle ID。")
        }
        guard betaConnected else { throw LabError("请先登录 TestFlight。") }
        let job = try create(title, source: .beta, state: .downloading, betaBundle: bundle, replacing: previous)
        let tracker = trackDownload(job.id, beta: true)
        defer { stopTracking(job.id, task: tracker) }
        do {
            let client = try await testFlight()
            _ = try await client.download(bundle: bundle, to: path(for: job, clear: false))
            stopTracking(job.id, task: tracker)
            try await received(job, automaticallyDecrypt: automaticallyDecrypt)
            return jobs.first(where: { $0.id == job.id }) ?? job
        } catch {
            set(job.id, .failed, friendly(error))
            throw error
        }
    }

    private func trackDownload(_ id: UUID, beta: Bool) -> Task<Void, Never> {
        if beta { IPALabResetTestFlightProgress() }
        downloads[id] = DownloadProgress()
        return Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var received: Int64 = 0
                var total: Int64 = 0
                let phase: Int32
                if beta {
                    phase = IPALabTestFlightProgress(&received, &total)
                } else {
                    IPAToolTransferProgress(&received, &total)
                    phase = received > 0 || total > 0 ? 1 : 0
                }
                let progress = DownloadProgress(received: max(0, received), total: max(0, total),
                                                transferring: phase == 1,
                                                preparingPackage: phase == 2 || (total > 0 && received >= total))
                if self.downloads[id] != progress { self.downloads[id] = progress }
                do { try await Task.sleep(nanoseconds: 350_000_000) }
                catch { return }
            }
        }
    }

    private func stopTracking(_ id: UUID, task: Task<Void, Never>) {
        task.cancel()
        downloads.removeValue(forKey: id)
    }

    @discardableResult func importIPA(_ url: URL, replacing previous: LocalJob? = nil,
                                     automaticallyDecrypt: Bool = true) async throws -> LocalJob {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let job = try create(url.deletingPathExtension().lastPathComponent, source: .local, state: .imported,
                             replacing: previous)
        do {
            let destination = path(for: job, clear: false)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: url, to: destination)
            }.value
            try await received(job, automaticallyDecrypt: automaticallyDecrypt)
            return jobs.first(where: { $0.id == job.id }) ?? job
        } catch {
            set(job.id, .failed, friendly(error))
            throw error
        }
    }

    private func received(_ job: LocalJob, automaticallyDecrypt: Bool = true) async throws {
        guard FairPlay.isCompleteIPA(path(for: job, clear: false)) else {
            throw LabError("下载或导入的原包不完整，或不是有效的 IPA。请重新下载或导入。")
        }
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].originalComplete = true }
        set(job.id, .imported)
        let receivedJob = jobs.first(where: { $0.id == job.id }) ?? job
        if automaticallyDecrypt && hasCredentials(for: receivedJob) { try await decrypt(receivedJob) }
    }

    func decrypt(_ job: LocalJob) async throws {
        guard let source = artifact(job, clear: false) else { throw LabError("原始 IPA 不在设备上。") }
        let credentials = candidateKeys(for: job)
        let models = self.credentials.filter(\.isEnrollment).map(\.data)
        guard !credentials.isEmpty || !models.isEmpty else { throw LabError("请导入匹配的 FairPlay 凭据，或从本机恢复模型。") }
        let destination = path(for: job, clear: true)
        set(job.id, .decrypting)
        do {
            let verified = try await Task.detached(priority: .userInitiated) { () -> Bool? in
                if !models.isEmpty, let result = try MacEnrollment.decrypt(source: source, destination: destination, models: models, resources: MacEnrollment.resources()) { return result }
                guard !credentials.isEmpty else { throw LabError("已保存的本机模型与此 IPA 许可证不匹配。请使用与本机相同的商店注册状态获取 IPA，或导入匹配的 credential.bin。") }
                try FairPlay.decrypt(source: source, destination: destination, keys: credentials)
                return nil
            }.value
            set(job.id, .ready, verified == false ? "解密已完成；部分映像没有可用的明文哈希，无法完成全部明文校验。" : nil)
        } catch {
            set(job.id, .failed, friendly(error))
            throw error
        }
    }

    func hasCredentials(for job: LocalJob) -> Bool { !candidateKeys(for: job).isEmpty || credentials.contains(where: \.isEnrollment) }

    private func candidateKeys(for job: LocalJob) -> [Data] {
        let owner = job.flow == .local ? nil : job.credentialOwner ?? activeProfile(beta: job.flow == .beta)?.owner
        return CredentialRecords.orderedKeys(credentials, preferredOwner: owner)
    }

    func friendly(_ error: Error) -> String {
        if let error = error as? StoreRuntime.Failure { return error.localizedDescription }
        if let error = error as? BetaCatalogFailure { return error.localizedDescription }
        if let error = error as? CatalogFailure { return error.localizedDescription }
        if let error = error as? StoreRecoveryFailure { return error.localizedDescription }
        if let error = error as? CredentialFileReader.Failure { return error.localizedDescription }
        if let error = error as? AppFileLibrary.Failure { return error.localizedDescription }
        if let error = error as? LabError { return error.message }
        if let error = error as? EnrollmentModelFormat.Failure { return error.localizedDescription }
        if let error = error as? StoreIssue { return error.message }
        if error is CancellationError { return "操作已取消。" }
        if error is URLError { return "无法连接 Apple 服务。请检查网络后重试。" }
        // Avoid displaying account/session material contained in provider responses.
        let summary = error.localizedDescription.lowercased()
        if summary.contains("authoriz") || summary.contains("session") || summary.contains("cookie") {
            return "Apple 拒绝了当前会话。请重新登录并确认账户具有该 App 的授权。"
        }
        if summary.contains("password") || summary.contains("authentication") || summary.contains("verification") {
            return "Apple 登录或验证码校验失败。请核对账户信息后重试。"
        }
        return "Apple 服务或 IPA 处理返回错误。请检查授权、文件格式和手机存储后重试。"
    }
}

private struct StoreReply: Decodable, Sendable {
    var state: [String: Data]?
    var apps: [AppResult]?
    var versions: [String]?
    var latest: String?
    var displayVersion: String?
    var error: Bool?
    var reason: String?
    var diagnostic: String?
}

private struct StoreRequest: Encodable, Sendable {
    let operation, device, email, password, code, query, path, bundle, version: String
    let id: UInt64
    let state: [String: Data]

    func perform() throws -> StoreReply {
        guard let resources = Bundle.main.resourceURL else { throw StoreRuntime.Failure.missing }
        _ = try StoreRuntime.prepare(resources: resources)
        let request = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        return try request.withCString { input in
            guard let output = IPAToolCall(UnsafeMutablePointer(mutating: input)) else {
                throw LabError("ipatool 无法完成请求。")
            }
            defer { IPAToolFree(output) }
            return try JSONDecoder().decode(StoreReply.self, from: Data(String(cString: output).utf8))
        }
    }
}

struct StoreIssue: LocalizedError {
    let message: String
    let diagnostic: String?
    let requiresAccountAction: Bool
    var errorDescription: String? { message }
}

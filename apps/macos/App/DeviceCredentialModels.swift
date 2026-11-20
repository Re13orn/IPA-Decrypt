import Foundation

struct JailbreakDevice: Decodable, Identifiable { let id, name, version: String }
struct ExtractionLicense: Decodable, Identifiable {
    let member, user, key: String
    var id: String { member }
}
struct InstalledLicense: Decodable, Identifiable {
    let path, appName, bundleID, user, key, digest, reason: String
    let supported: Bool
    var credentialMatch: String?
    var metadataAccount: String?
    var downloadAccounts: [String]?
    var id: String { path }
}
struct InstalledCredentialGroup: Identifiable {
    let id: String
    let credentialID: String?
    let members: [InstalledLicense]
    static func make(_ items: [InstalledLicense]) -> [Self] {
        let groups = Dictionary(grouping: items) { item in
            item.credentialMatch.map { "credential:" + $0 } ?? "license:" + item.id
        }
        return groups.map { id, members in Self(id: id, credentialID: members.first?.credentialMatch, members: members) }
            .sorted { ($0.members.first?.appName ?? "") < ($1.members.first?.appName ?? "") }
    }
}
struct CredentialProbe: Encodable { let id: String; let data: Data }
struct CredentialBatchPlan {
    var attempted = Set<String>()
    var failures: [String: String] = [:]
    func next(in licenses: [InstalledLicense]) -> InstalledLicense? {
        licenses.first { $0.supported && $0.credentialMatch == nil && !attempted.contains($0.id) }
    }
    mutating func reconcile(_ licenses: [InstalledLicense]) {
        let pending = Set(licenses.filter { $0.supported && $0.credentialMatch == nil }.map(\.id))
        failures = failures.filter { pending.contains($0.key) }
    }
}

struct DownloadLicenseReference { let owner: String; let ipa: URL; let member: String; let user: String }

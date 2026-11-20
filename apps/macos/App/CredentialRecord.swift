import Foundation
import CryptoKit

struct CredentialLicenseEvidence: Codable, Equatable {
    let appName: String
    let bundleID: String
    let user: String
    let key: String
    let triggerUser: String
    let triggerKey: String
    var installedPath: String?
    var installedDigest: String?
}

struct FairPlayCredential: Codable, Identifiable {
    var id = UUID()
    var owner: String?
    let data: Data
    var label: String?
    var addedAt: Date?
    var origin: String?
    var verifiedLicenses: [CredentialLicenseEvidence]?

    var hex: String { data.map { String(format: "%02x", $0) }.joined() }
    var fingerprint: String { SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined() }
    var displayName: String { label?.isEmpty == false ? label! : "凭据 " + String(fingerprint.prefix(8)).uppercased() }
}

struct CredentialGroup: Identifiable {
    let owner: String?
    let records: [FairPlayCredential]
    var id: String { owner.map { "account:" + $0 } ?? "unbound" }
    var title: String { owner ?? "未绑定 Apple ID" }

    static func make(records: [FairPlayCredential], accounts: [String]) -> [CredentialGroup] {
        let owners = Set(accounts + records.compactMap(\.owner)).sorted()
        var groups = owners.map { owner in CredentialGroup(owner: owner, records: records.filter { $0.owner == owner }) }
        let unbound = records.filter { $0.owner == nil }
        if !unbound.isEmpty || groups.isEmpty { groups.append(.init(owner: nil, records: unbound)) }
        return groups
    }
}

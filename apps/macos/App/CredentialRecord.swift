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

    var kind: String?
    var enrollmentSelector: String?
    var plaintextVerified: Bool?
    var sourceApp: String?
    var isEnrollment: Bool { kind == "mac-enrollment" }
    var formatName: String { isEnrollment ? "Mac 本机模型" : "16 字节凭据" }

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

enum CredentialRecords {
    static func orderedKeys(_ records: [FairPlayCredential], preferredOwner: String?) -> [Data] {
        let valid = records.filter { !$0.isEnrollment && $0.data.count == 16 }
        let ordered = valid.filter { $0.owner == preferredOwner || $0.owner == nil } + valid.filter { $0.owner != preferredOwner && $0.owner != nil }
        var seen = Set<Data>()
        return ordered.compactMap { seen.insert($0.data).inserted ? $0.data : nil }
    }
}

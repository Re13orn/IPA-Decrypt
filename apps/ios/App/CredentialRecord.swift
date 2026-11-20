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
    var verificationKind: String?
    var sourceName: String?
    var sourceJobID: UUID?
    var verifiedAt: Date?
    var downloadOwner: String?

    func sameSource(as other: Self) -> Bool {
        appName == other.appName && bundleID == other.bundleID && user == other.user && key == other.key &&
        verificationKind == other.verificationKind && sourceJobID == other.sourceJobID && sourceName == other.sourceName && downloadOwner == other.downloadOwner
    }
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
    var displayName: String { label?.isEmpty == false ? label! : "凭据 " + fingerprint.prefix(8).uppercased() }
}

struct CredentialContentGroup: Identifiable {
    let records: [FairPlayCredential]
    var id: UUID { records[0].id }
    var data: Data { records[0].data }
    var fingerprint: String { records[0].fingerprint }
    var contentID: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var displayName: String { records.first(where: { $0.label?.isEmpty == false })?.displayName ?? records[0].displayName }
    var owners: [String] { Array(Set(records.compactMap(\.owner))).sorted() }
    var hasUnbound: Bool { records.contains { $0.owner == nil } }
    var origins: [String] { Array(Set(records.compactMap(\.origin))).sorted() }
    var evidence: [CredentialLicenseEvidence] { records.reduce([]) { CredentialRecords.mergeEvidence($0, $1.verifiedLicenses ?? []) } }
    static func make(_ records: [FairPlayCredential]) -> [Self] {
        var seen = Set<Data>()
        return records.compactMap { record in
            guard seen.insert(record.data).inserted else { return nil }
            return Self(records: records.filter { $0.data == record.data })
        }
    }
}

enum CredentialRecords {
    static func mergeEvidence(_ old: [CredentialLicenseEvidence], _ incoming: [CredentialLicenseEvidence]) -> [CredentialLicenseEvidence] {
        var result = old
        for proof in incoming {
            if let index = result.firstIndex(where: { $0.sameSource(as: proof) }) { result[index] = proof }
            else { result.append(proof) }
        }
        return result
    }
    static func orderedKeys(_ records: [FairPlayCredential], preferredOwner: String?) -> [Data] {
        let ordered = records.filter { $0.owner == preferredOwner || $0.owner == nil } + records.filter { $0.owner != preferredOwner && $0.owner != nil }
        var seen = Set<Data>()
        return ordered.compactMap { seen.insert($0.data).inserted ? $0.data : nil }
    }
}

struct CredentialVerificationMatch {
    let data: Data
    let evidence: CredentialLicenseEvidence
}

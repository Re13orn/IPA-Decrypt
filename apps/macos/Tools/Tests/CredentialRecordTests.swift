import Foundation
@main struct CredentialRecordTests {
    static func main() throws {
        let id = UUID()
        let bytes = Data(0..<16)
        let legacy: [String: Any] = ["id": id.uuidString, "owner": "fixture@example.invalid", "data": bytes.base64EncodedString()]
        let old = try JSONDecoder().decode(FairPlayCredential.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.id == id && old.data == bytes && old.owner == "fixture@example.invalid")
        precondition(old.verifiedLicenses == nil)
        precondition(old.label == nil && old.addedAt == nil && old.origin == nil)
        precondition(old.hex == "000102030405060708090a0b0c0d0e0f")
        let other = FairPlayCredential(owner: nil, data: bytes, label: "fixture", addedAt: Date(), origin: "测试")
        precondition(old.fingerprint == other.fingerprint)
        let roundTrip = try JSONDecoder().decode(FairPlayCredential.self, from: JSONEncoder().encode(other))
        precondition(roundTrip.label == "fixture" && roundTrip.data == bytes && roundTrip.origin == "测试")
        let proof = CredentialLicenseEvidence(appName: "Fixture", bundleID: "example.fixture", user: "01020304", key: "00000001", triggerUser: "01020304", triggerKey: "00000001")
        var verified = other; verified.verifiedLicenses = [proof]
        let verifiedRoundTrip = try JSONDecoder().decode(FairPlayCredential.self, from: JSONEncoder().encode(verified))
        precondition(verifiedRoundTrip.verifiedLicenses == [proof])
        let groups = CredentialGroup.make(records: [old, other], accounts: ["empty@example.invalid", "fixture@example.invalid"])
        precondition(groups.count == 3)
        precondition(groups.first { $0.owner == "fixture@example.invalid" }?.records.first?.id == id)
        precondition(groups.first { $0.owner == "empty@example.invalid" }?.records.isEmpty == true)
        precondition(groups.last?.owner == nil && groups.last?.records.count == 1)
        let preferred = FairPlayCredential(owner: "preferred@example.invalid", data: Data(repeating: 1, count: 16))
        let unbound = FairPlayCredential(owner: nil, data: Data(repeating: 2, count: 16))
        let differentlyLabelled = FairPlayCredential(owner: "other@example.invalid", data: Data(repeating: 3, count: 16))
        let duplicate = FairPlayCredential(owner: "other@example.invalid", data: preferred.data)
        let model = FairPlayCredential(owner: nil, data: Data(repeating: 4, count: 16), kind: "mac-enrollment")
        let malformed = FairPlayCredential(owner: nil, data: Data(repeating: 5, count: 15))
        let candidates = CredentialRecords.orderedKeys([differentlyLabelled, preferred, unbound, duplicate, model, malformed], preferredOwner: preferred.owner)
        precondition(candidates == [preferred.data, unbound.data, differentlyLabelled.data])
        print("PASS credential legacy migration, metadata round-trip, hex representation, fingerprints and Apple ID grouping")
    }
}

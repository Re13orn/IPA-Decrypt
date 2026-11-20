import Foundation
@main struct CredentialRecordTests {
    static func main() throws {
        let a = Data(0..<16), b = Data(repeating: 42, count: 16)
        let legacy: [[String: Any]] = [["id":UUID().uuidString,"data":a.base64EncodedString(),"owner":"one@example.invalid"], ["id":UUID().uuidString,"data":a.base64EncodedString(),"owner":"two@example.invalid"]]
        let records = try JSONDecoder().decode([FairPlayCredential].self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(records.allSatisfy { $0.verifiedLicenses == nil && $0.label == nil && $0.addedAt == nil })
        let groups = CredentialContentGroup.make(records)
        precondition(groups.count == 1 && groups[0].records.count == 2 && groups[0].owners.count == 2)
        precondition(groups[0].contentID.count == 64 && groups[0].fingerprint.count == 16)
        let unbound = FairPlayCredential(data:b, label:"fixture",addedAt:Date(),origin:"十六进制导入")
        let ordered = CredentialRecords.orderedKeys(records + [unbound], preferredOwner:"wrong@example.invalid")
        precondition(ordered == [b,a]) // labels prioritize; they must not exclude a valid key.
        var proof = CredentialLicenseEvidence(appName:"Fixture",bundleID:"example.fixture",user:"01020304",key:"00000002",triggerUser:"01020304",triggerKey:"00000002", verificationKind:"ipa-license",sourceName:"Fixture.ipa",sourceJobID:UUID(),verifiedAt:Date(),downloadOwner:"one@example.invalid")
        var record = records[0]; record.verifiedLicenses=[proof]; record.label="name"
        proof.verifiedAt=Date().addingTimeInterval(60)
        let merged = CredentialRecords.mergeEvidence(record.verifiedLicenses!,[proof])
        precondition(merged.count == 1 && merged[0].verifiedAt == proof.verifiedAt)
        record.verifiedLicenses=merged
        let decoded=try JSONDecoder().decode(FairPlayCredential.self,from:JSONEncoder().encode(record))
        precondition(decoded.verifiedLicenses == merged && decoded.owner == records[0].owner && decoded.label == "name")
        let combined=CredentialContentGroup.make([record,records[1]])[0]
        precondition(combined.evidence.count == 1 && combined.owners.count == 2)
        print("PASS iOS legacy metadata compatibility, exact-content grouping with owner preservation, unique key ordering and proof refresh")
    }
}

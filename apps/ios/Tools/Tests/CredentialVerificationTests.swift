import Foundation
@main struct CredentialVerificationTests {
    static func main() throws {
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1])
        precondition(FairPlay.isCompleteIPA(fixture.appendingPathComponent("target.ipa")))
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let full=try Data(contentsOf:fixture.appendingPathComponent("target.ipa"))
        try full.prefix(full.count / 2).write(to:temporary)
        precondition(!FairPlay.isCompleteIPA(temporary))
        precondition(!FairPlay.isCompleteIPA(fixture.appendingPathComponent("missing.ipa")))
        let valid=try Data(contentsOf:fixture.appendingPathComponent("credential.bin")), wrong=Data(repeating:0xff,count:16)
        let job=UUID()
        let matches=FairPlay.matchingLicenses(source:fixture.appendingPathComponent("target.ipa"), keys:[wrong,valid,valid],sourceName:"fixture",sourceJobID:job,downloadOwner:"download@example.invalid")
        precondition(matches.count == 1 && matches[0].data == valid)
        let proof=matches[0].evidence
        precondition(proof.user == "01020304" && proof.key == "00000001" && proof.sourceJobID == job && proof.verifiedAt != nil)
        precondition(proof.downloadOwner == "download@example.invalid" && proof.verificationKind == "ipa-license")
        let local=FairPlay.matchingLicenses(source:fixture.appendingPathComponent("target.ipa"),keys:[valid],sourceName:"local",sourceJobID:nil,downloadOwner:nil)
        precondition(local.count == 1 && local[0].evidence.downloadOwner == nil)
        precondition(FairPlay.matchingLicenses(source:fixture.appendingPathComponent("target.ipa"),keys:[wrong],sourceName:"wrong",sourceJobID:nil,downloadOwner:nil).isEmpty)
        precondition(FairPlay.matchingLicenses(source:fixture.appendingPathComponent("absent.ipa"),keys:[valid],sourceName:"missing",sourceJobID:nil,downloadOwner:nil).isEmpty)
        precondition(CredentialRecords.mergeEvidence([proof],[proof]).count == 1)
        print("PASS iOS license validation: known key, wrong-key rejection, exact matching key, deduplication and download provenance vs unknown local origin")
    }
}

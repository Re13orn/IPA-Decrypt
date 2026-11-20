import Foundation
import ZIPFoundation
@main struct FairPlayTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let candidate = try Data(contentsOf: fixture.appendingPathComponent("credential.bin"))
        precondition(FairPlay.credentialMatchesIPA(candidate, source: fixture.appendingPathComponent("target.ipa"), member: "Payload/Test.app/SC_Info/Test.sinf"))
        precondition(!FairPlay.credentialMatchesIPA(Data(repeating:0,count:16), source: fixture.appendingPathComponent("target.ipa"), member: "Payload/Test.app/SC_Info/Test.sinf"))
        precondition(!FairPlay.credentialMatchesIPA(candidate, source: fixture.appendingPathComponent("target.ipa"), member: "missing.sinf"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        precondition(FairPlay.isCompleteIPA(fixture.appendingPathComponent("target.ipa")))
        let partial = directory.appendingPathComponent("partial.ipa")
        let full = try Data(contentsOf: fixture.appendingPathComponent("target.ipa"))
        try full.prefix(full.count / 2).write(to: partial)
        precondition(!FairPlay.isCompleteIPA(partial))
        precondition(!FairPlay.isCompleteIPA(directory))
        precondition(!FairPlay.isCompleteIPA(directory.appendingPathComponent("missing.ipa")))
        let unchanged = try Data(contentsOf: fixture.appendingPathComponent("target.ipa")); precondition(unchanged == full)
        let output = directory.appendingPathComponent("decrypted.ipa")
        try FairPlay.decrypt(source: fixture.appendingPathComponent("encrypted.ipa"), destination: output,
                             keys: [Data(contentsOf: fixture.appendingPathComponent("credential.bin"))])
        let archive = try Archive(url: output, accessMode: .read)
        let member = archive["Payload/Test.app/Test"]!
        var data = Data()
        let crc = try archive.extract(member) { data.append($0) }
        precondition(crc == member.checksum)
        precondition(data[48..<52].allSatisfy { $0 == 0 })
        let expected = try Data(contentsOf: fixture.appendingPathComponent("expected.bin"))
        precondition(data.suffix(4096) == expected)
        let rejected = directory.appendingPathComponent("wrong.ipa")
        do {
            try FairPlay.decrypt(source: fixture.appendingPathComponent("encrypted.ipa"), destination: rejected, keys: [Data(repeating: 0xff, count: 16)])
            preconditionFailure("Wrong credential accepted")
        } catch { precondition(!FileManager.default.fileExists(atPath: rejected.path)) }
        print("PASS Mac FairPlay: plaintext, CRC, cryptid and wrong-key rejection")
    }
}

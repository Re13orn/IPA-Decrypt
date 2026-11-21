// Shared Mac/iOS synthetic vector, independent of accounts and device credentials.
import Foundation
import ZIPFoundation
@main struct DecryptionVectorTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = fixture.appendingPathComponent("encrypted.ipa")
        let inputBefore = try Data(contentsOf: input)
        let output = directory.appendingPathComponent("clear.ipa")
        let key = try Data(contentsOf: fixture.appendingPathComponent("credential.bin"))
        try FairPlay.decrypt(source: input, destination: output, keys: [Data(repeating: 0xff, count: 16), key])
        let archive = try Archive(url: output, accessMode: .read)
        guard let member = archive["Payload/Test.app/Test"] else { fatalError("Missing plaintext executable") }
        var data = Data()
        let checksum = try archive.extract(member) { data.append($0) }
        precondition(checksum == member.checksum)
        precondition(data[48..<52].allSatisfy { $0 == 0 })
        let expected = try Data(contentsOf: fixture.appendingPathComponent("expected.bin"))
        precondition(data.suffix(4096) == expected)
        let inputAfter = try Data(contentsOf: input)
        precondition(inputAfter == inputBefore)
        let rejected = directory.appendingPathComponent("wrong.ipa")
        do {
            try FairPlay.decrypt(source: input, destination: rejected, keys: [Data(repeating: 0xff, count: 16)])
            preconditionFailure("Wrong key accepted")
        } catch { precondition(!FileManager.default.fileExists(atPath: rejected.path)) }
        print("PASS synthetic decrypt: plaintext, CRC, cryptid, wrong-key rejection and unchanged input")
    }
}

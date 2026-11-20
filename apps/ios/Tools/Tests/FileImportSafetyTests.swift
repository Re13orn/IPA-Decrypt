import Foundation

@main struct FileImportSafetyTests {
    static func main() throws {
        precondition(FileImportSafety.kind(of: URL(fileURLWithPath: "/tmp/credential.BIN")) == .credential)
        precondition(FileImportSafety.kind(of: URL(fileURLWithPath: "/tmp/test.ipa")) == .ipa)
        precondition(FileImportSafety.kind(of: URL(string: "https://example.com/credential.bin")!) == nil)
        precondition(FileImportSafety.kind(of: URL(string: "file://remote/credential.bin")!) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credential.bin")
        for count in [0, 15, 16, 17, 1048576] {
            let original = Data(repeating: 0x42, count: count)
            try original.write(to: file)
            do {
                let actual = try CredentialFileReader.read(file)
                precondition(count == 16 && actual == original)
            } catch { precondition(count != 16) }
            let after = try Data(contentsOf: file)
            precondition(after == original, "Source file changed")
        }
        let folder = directory.appendingPathComponent("folder.bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { _ = try CredentialFileReader.read(folder); preconditionFailure("Accepted directory") } catch { }
        try FileManager.default.removeItem(at: file)
        do { _ = try CredentialFileReader.read(file); preconditionFailure("Accepted missing file") } catch { }
        let library = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 16).write(to: file)
        let received = try AppFileLibrary.receive(file, root: library)
        precondition(received != file && AppFileLibrary.contains(received, root: library))
        let receivedBytes = try CredentialFileReader.read(received)
        precondition(receivedBytes == Data(repeating: 0x33, count: 16))
        let duplicate = try AppFileLibrary.receive(file, root: library)
        precondition(duplicate != received)
        let alreadyInside = try AppFileLibrary.receive(received, root: library)
        precondition(alreadyInside == received)
        let imports = received.deletingLastPathComponent()
        try Data([1]).write(to: imports.appendingPathComponent("test.ipa"))
        try FileManager.default.createSymbolicLink(at: imports.appendingPathComponent("outside.bin"), withDestinationURL: file)
        let credentials = try AppFileLibrary.entries(in: imports, kind: .credential, root: library)
        precondition(credentials.count == 2 && credentials.allSatisfy { $0.url.pathExtension == "bin" })
        let ipas = try AppFileLibrary.entries(in: imports, kind: .ipa, root: library)
        precondition(ipas.count == 1)
        precondition(!AppFileLibrary.contains(directory.appendingPathComponent("library-other"), root: library))
        do { _ = try AppFileLibrary.entries(in: directory, kind: .credential, root: library); preconditionFailure("Listed outside library") } catch { }
        print("Library: received files preserved, duplicate names retained, per-type listing and symlink/container boundaries passed")
        print("Credential coordinated reads: 16 bytes accepted; empty, truncated, oversized, directory, missing and remote files rejected; source bytes unchanged")
    }
}

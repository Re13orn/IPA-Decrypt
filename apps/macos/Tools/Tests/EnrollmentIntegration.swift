// Opt-in local controls. Never put real state or app paths in this file.
import Foundation
struct LabError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
@main struct EnrollmentIntegration {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: integration resources snapshot installed-app") }
        let resources = URL(fileURLWithPath: args[1]), snapshot = URL(fileURLWithPath: args[2]), app = URL(fileURLWithPath: args[3])
        let recovered = try MacEnrollment.recover(app: .init(url: app, name: "Private control"), resources: resources, snapshot: snapshot)
        if !recovered.verified { throw LabError("recovery control unverified") }
        let root = try MacEnrollment.privateDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.ipa"), result = root.appendingPathComponent("result.ipa")
        try MacEnrollment.archiveInstalledApp(app, to: input)
        let first = try MacEnrollment.decrypt(source: input, destination: result, models: [recovered.data, recovered.data], resources: resources); if first != true { throw LabError("model decryption control failed") }
        precondition(FileManager.default.fileExists(atPath: result.path))
        // Replacing a successful export must also be atomic and preserve a valid IPA.
        let replaced = try MacEnrollment.decrypt(source: input, destination: result, models: [recovered.data], resources: resources); if replaced != true { throw LabError("replacement control failed") }
        var wrong = recovered.data; wrong[48] ^= 1
        let mismatch = try MacEnrollment.decrypt(source: input, destination: result, models: [wrong], resources: resources); if mismatch != nil { throw LabError("mismatch control failed") }
        let task = Task.detached { try MacEnrollment.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], in: root) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; fatalError("cancellation ignored") } catch is CancellationError { }
        print("PASS private service controls: snapshot recovery, installed archive, model decryption, duplicate deduplication, atomic replacement, selector mismatch, process cancellation")
    }
}

import Foundation
@main struct JobRecoveryTests {
    static func main() throws {
        let id = UUID()
        let old: [String: Any] = ["id":id.uuidString,"name":"Fixture","source":"App Store","state":"failed","credentialOwner":"fixture@example.invalid","version":"123"]
        let legacy = try JSONDecoder().decode(LocalJob.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(legacy.originalComplete == nil && legacy.id == id)
        let complete = legacy.recovered(originalIsComplete: true)
        let partial = legacy.recovered(originalIsComplete: false)
        precondition(complete.originalComplete == true && partial.originalComplete == false)
        precondition(complete.credentialOwner == legacy.credentialOwner && complete.version == "123")
        precondition(complete.state == .failed)
        for state in [LocalJob.State.downloading, .decrypting] {
            var job=legacy; job.state=state
            let kept=job.recovered(originalIsComplete:true)
            let restart=job.recovered(originalIsComplete:false)
            precondition(kept.state == .failed && kept.note!.contains("完整原包已保留"))
            precondition(restart.state == .failed && restart.note!.contains("不完整"))
        }
        var ready=complete; ready.state = .ready
        precondition(ready.recovered(originalIsComplete:true).state == .ready)
        let roundtrip=try JSONDecoder().decode(LocalJob.self,from:JSONEncoder().encode(complete))
        precondition(roundtrip.id == id && roundtrip.originalComplete == true)
        print("PASS legacy job migration, owner/version preservation, interrupted download/decrypt recovery and complete/partial markers")
    }
}

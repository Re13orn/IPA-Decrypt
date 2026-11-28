import Foundation

@main struct MacQueueTests {
    static func main() throws {
        let app = AppResult(trackId: 42, trackName: "Queue fixture", bundleId: "local.queue.fixture", version: "1", artworkUrl60: nil, price: 0)
        var original = MacQueuedOperation(kind: .store, name: app.trackName, app: app, owner: "first@example.test", decryptAfterwards: false)
        var queue = MacQueueSnapshot()
        precondition(queue.append(original))
        var decrypting = original; decrypting.id = UUID(); decrypting.decryptAfterwards = true
        precondition(!queue.append(decrypting))
        precondition(queue.operations.count == 1 && queue.operations[0].decryptAfterwards)
        var anotherAccount = original; anotherAccount.owner = "second@example.test"
        precondition(queue.append(anotherAccount), "Independent accounts must not merge")
        var older = original; older.version = "123456"
        precondition(queue.append(older), "Different versions must remain distinct")

        queue.operations[0].state = .failed
        let jobID = UUID(); queue.operations[0].jobID = jobID
        precondition(queue.append(original))
        precondition(queue.operations.count == 3 && queue.operations[0].jobID == jobID,
                     "Retry must preserve the existing record, rather than create a second download")

        original.state = .running
        queue.operations = [original]
        precondition(!queue.append(decrypting))
        precondition(!queue.operations[0].decryptAfterwards, "A duplicate click must not re-enable an active task's stopped follow-up")
        queue.operations[0].previousJobIDs = [jobID]
        queue.recover()
        precondition(queue.paused && queue.operations[0].state == .failed)
        precondition(queue.operations[0].problem != nil)
        let data = try JSONEncoder().encode(queue)
        let restored = try JSONDecoder().decode(MacQueueSnapshot.self, from: data)
        precondition(restored.paused && restored.operations[0].owner == "first@example.test")
        precondition(restored.operations[0].app?.bundleId == app.bundleId)
        precondition(restored.operations[0].previousJobIDs == [jobID])

        var files = MacQueueSnapshot()
        let first = MacQueuedOperation(kind: .importFile, name: "File", file: URL(fileURLWithPath: "/tmp/queue-fixture.ipa"))
        precondition(files.append(first)); precondition(!files.append(first))
        let decrypt = MacQueuedOperation(kind: .decrypt, name: "File", jobID: jobID)
        precondition(files.append(decrypt)); precondition(!files.append(decrypt))
        print("PASS: queue deduplication, account/version isolation, retry record preservation, paused restart and metadata roundtrip")
    }
}

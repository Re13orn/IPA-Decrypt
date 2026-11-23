import Foundation

@main struct StoreRuntimeTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources")
        try fm.createDirectory(at: resources.appendingPathComponent("StoreRuntime"), withIntermediateDirectories: true)
        let archive = resources.appendingPathComponent("StoreRuntime/unicorn.whl")
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: archive)
        let cache = root.appendingPathComponent("Cache")
        let library = try StoreRuntime.prepare(resources: resources, cache: cache)
        let contents = try Data(contentsOf: library)
        precondition(StoreRuntime.digest(contents) == StoreRuntime.libraryHash)
        try Data("corrupted cache".utf8).write(to: library)
        _ = try StoreRuntime.prepare(resources: resources, cache: cache)
        let repaired = try Data(contentsOf: library)
        precondition(StoreRuntime.digest(repaired) == StoreRuntime.libraryHash)
        try Data("corrupted package".utf8).write(to: archive)
        do {
            _ = try StoreRuntime.prepare(resources: resources, cache: root.appendingPathComponent("FreshCache"))
            preconditionFailure("Corrupted archive accepted")
        } catch StoreRuntime.Failure.invalid { }
        try fm.removeItem(at: archive)
        do {
            _ = try StoreRuntime.prepare(resources: resources, cache: root.appendingPathComponent("FreshCache"))
            preconditionFailure("Missing archive accepted")
        } catch StoreRuntime.Failure.missing { }
        print("PASS: offline extraction, corrupt cache repair, invalid/missing package rejection")
    }
}

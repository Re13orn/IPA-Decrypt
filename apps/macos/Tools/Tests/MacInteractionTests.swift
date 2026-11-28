import Foundation

@main struct MacInteractionTests {
    static func main() throws {
        var requests = LatestViewRequest()
        let first = requests.begin()
        let second = requests.begin()
        precondition(!requests.contains(first))
        precondition(!requests.finish(first), "A cancelled old request must not clear the current loading state")
        precondition(requests.contains(second))
        requests.invalidate()
        precondition(!requests.contains(second), "A closed or changed view must reject late results")
        let third = requests.begin()
        precondition(requests.finish(third))
        precondition(!requests.finish(third))

        // Enter TestFlight during a search: wait, then load exactly when idle.
        precondition(!MacCatalogLoading.shouldLoadBeta(visible: true, connected: true, busy: true, loaded: false, failed: false))
        precondition(MacCatalogLoading.shouldLoadBeta(visible: true, connected: true, busy: false, loaded: false, failed: false))
        precondition(!MacCatalogLoading.shouldLoadBeta(visible: true, connected: true, busy: false, loaded: true, failed: false))
        precondition(!MacCatalogLoading.shouldLoadBeta(visible: true, connected: true, busy: false, loaded: false, failed: true),
                     "Failure requires explicit retry, rather than repeatedly authenticating")
        precondition(!MacCatalogLoading.shouldLoadBeta(visible: false, connected: true, busy: false, loaded: false, failed: false))
        print("PASS: late-request rejection; beta auto-load after busy state; no automatic error retry loop")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ipa")
        let target = root.appendingPathComponent("export.ipa")
        let payload = Data(repeating: 0x71, count: 1024 * 1024)
        try payload.write(to: source)
        try IPAFileExporter.copy(from: source, to: target)
        precondition((try? Data(contentsOf: target)) == payload)
        try Data("previous export".utf8).write(to: target)
        try IPAFileExporter.copy(from: source, to: target)
        precondition((try? Data(contentsOf: target)) == payload)
        try IPAFileExporter.copy(from: source, to: source)
        precondition((try? Data(contentsOf: source)) == payload)
        do {
            try IPAFileExporter.copy(from: root.appendingPathComponent("missing.ipa"), to: target)
            preconditionFailure("Missing source must fail")
        } catch { }
        precondition((try? Data(contentsOf: target)) == payload, "A failed export must preserve the previous file")
        let directory = root.appendingPathComponent("directory.ipa")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try IPAFileExporter.copy(from: source, to: directory)
            preconditionFailure("A directory must not be replaced")
        } catch { }
        let remaining = try fm.contentsOfDirectory(atPath: root.path)
        precondition(!remaining.contains(where: { $0.hasPrefix(".ipa-export-") }))
        print("PASS: IPA export create/overwrite/same-file; failed export preserves destination; temporary copies removed")
    }
}

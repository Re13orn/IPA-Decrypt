import Foundation

@main struct InstalledAppDiscoveryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for name in ["Top.app", "Category/Deep/Nested.app", "Top.app/Contents/Helpers/Helper.app", ".Hidden/Hidden.app"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("NotAnApp.app"))
        let apps = InstalledAppDiscovery.applications(in: [root, root.appendingPathComponent("Category"), root.appendingPathComponent("Missing")])
        precondition(Set(apps.map { $0.lastPathComponent }) == ["Top.app", "Nested.app"])
        precondition(apps.count == 2, "Overlapping roots must not duplicate applications")
        print("PASS: nested apps found; bundles, hidden folders and duplicate roots excluded")
    }
}

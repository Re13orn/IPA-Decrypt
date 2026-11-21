import Foundation

enum InstalledAppDiscovery {
    static func applications(in roots: [URL]) -> [URL] {
        let manager = FileManager.default
        var seen = Set<String>()
        var apps: [URL] = []
        for root in roots {
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                guard url.pathExtension.lowercased() == "app" else { continue }
                // App bundles may contain helpers or wrapped iOS apps; list only the outer app.
                entries.skipDescendants()
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                if seen.insert(resolved.path).inserted { apps.append(url) }
            }
        }
        return apps
    }
}

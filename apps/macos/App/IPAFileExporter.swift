import Foundation

enum IPAFileExporter {
    /// Stage a filesystem copy beside the destination, then replace atomically.
    /// Never read a potentially large IPA into an in-memory Data value.
    static func copy(from source: URL, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let original = source.resolvingSymlinksInPath().standardizedFileURL
        guard try original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        if original == destination.resolvingSymlinksInPath().standardizedFileURL { return }
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".ipa-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: original, to: staged)
        if exists { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: destination) }
    }
}

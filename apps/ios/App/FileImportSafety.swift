import Foundation

enum FileImportSafety {
    enum Kind { case ipa, credential }

    static func kind(of url: URL) -> Kind? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        switch url.pathExtension.lowercased() {
        case "ipa": return .ipa
        case "bin": return .credential
        default: return nil
        }
    }
}

// Provider coordination happens off the UI thread. Scope and file handles are
// released on every path; the source file is never changed or bookmarked.
enum CredentialFileReader {
    enum Failure: LocalizedError {
        case invalidFile
        var errorDescription: String? { "请选择恰好 16 字节的 credential.bin 文件。" }
    }
    static func read(_ url: URL) throws -> Data {
        guard FileImportSafety.kind(of: url) == .credential else { throw Failure.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
            result = Result {
                let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw Failure.invalidFile }
                let handle = try FileHandle(forReadingFrom: coordinated)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 17), data.count == 16 else { throw Failure.invalidFile }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalidFile }
        return try result.get()
    }
}

// The browser is deliberately limited to Documents. Account/session storage is
// in Library/Application Support and is never listed or shared through Finder.
enum AppFileLibrary {
    struct Entry: Identifiable {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        var id: String { url.path }
    }
    enum Failure: LocalizedError {
        case unsupported, outsideLibrary
        var errorDescription: String? {
            switch self {
            case .unsupported: return "请选择 IPA 或 .bin 文件。"
            case .outsideLibrary: return "无法访问此文件位置。"
            }
        }
    }
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static func contains(_ url: URL, root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return url.isFileURL && (path == base || path.hasPrefix(base + "/"))
    }
    static func entries(in directory: URL, kind: FileImportSafety.Kind, root: URL = root) throws -> [Entry] {
        guard contains(directory, root: root) else { throw Failure.outsideLibrary }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]).compactMap { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, contains(url, root: root) else { return nil }
                if values.isDirectory == true { return Entry(url: url, isDirectory: true, size: 0) }
                guard values.isRegularFile == true, FileImportSafety.kind(of: url) == kind else { return nil }
                return Entry(url: url, isDirectory: false, size: Int64(values.fileSize ?? 0))
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
    }
    static func receive(_ source: URL, root: URL = root) throws -> URL {
        guard FileImportSafety.kind(of: source) != nil else { throw Failure.unsupported }
        // An Open-In copy already in Inbox needs no additional copy.
        if contains(source, root: root) {
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.unsupported }
            return source
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let imports = root.appendingPathComponent("传入文件", isDirectory: true)
        guard contains(imports, root: root) else { throw Failure.outsideLibrary }
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            result = Result {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.unsupported }
                var target = imports.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    target = imports.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                }
                try FileManager.default.copyItem(at: url, to: target)
                return target
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.unsupported }
        return try result.get()
    }
}


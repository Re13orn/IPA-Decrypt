import Foundation
import CryptoKit
import ZIPFoundation

enum StoreRuntime {
    static let archiveHash = "d6c93e0f60328d8f4a1792af3f834137a28050fcc2305f2ec01efe8558a9844e"
    static let libraryHash = "7207c8e3d7a63118fb0bca73e01816797fd51b1d8a39a4cbc7abfd562ee59c85"
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    enum Failure: LocalizedError {
        case missing, invalid, cache, engine(String)
        var errorDescription: String? {
            switch self {
            case .missing: return "安装包缺少设备证明运行库，请重新下载安装。\n诊断：login/runtime-bundle-missing"
            case .invalid: return "设备证明运行库校验失败，请重新下载安装。\n诊断：login/runtime-bundle-invalid"
            case .cache: return "无法准备设备证明运行库，请检查用户缓存目录权限和可用空间。\n诊断：login/runtime-cache-write"
            case .engine(let code): return "设备证明组件自检失败。\n诊断：" + code
            }
        }
    }

    // Use the same HOME/Library/Caches path as Go's os.UserCacheDir on macOS.
    static func prepare(resources: URL, cache: URL? = nil) throws -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root = cache ?? home.appendingPathComponent("Library/Caches")
        let directory = root.appendingPathComponent("ipatool/unicorn/2.1.4/" + libraryHash)
        let destination = directory.appendingPathComponent("libunicorn.2.dylib")
        let fm = FileManager.default
        if let attrs = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) < 64*1024*1024,
           let data = try? Data(contentsOf: destination), digest(data) == libraryHash { return destination }
        let archiveURL = resources.appendingPathComponent("StoreRuntime/unicorn.whl")
        guard fm.fileExists(atPath: archiveURL.path) else { throw Failure.missing }
        guard let size = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 64*1024*1024, let bytes = try? Data(contentsOf: archiveURL), digest(bytes) == archiveHash else { throw Failure.invalid }
        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .read) }
        catch { throw Failure.invalid }
        guard let entry = archive["unicorn/lib/libunicorn.2.dylib"], entry.type == .file,
              entry.uncompressedSize < 64*1024*1024 else { throw Failure.invalid }
        var data = Data()
        do {
            let crc = try archive.extract(entry) { data.append($0) }
            guard crc == entry.checksum, digest(data) == libraryHash else { throw Failure.invalid }
        } catch { throw Failure.invalid }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.cache }
            try data.write(to: destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { throw Failure.cache }
        return destination
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Swift implementation based on EthanArbuckle/fairplay-decrypt's core.py and decrypt.py.
import CommonCrypto
import CryptoKit
import Foundation
import ZIPFoundation

struct LabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum FairPlay {
    // Structural recovery check only; decryption still verifies payload data and licenses.
    static func isCompleteIPA(_ file: URL) -> Bool {
        guard let archive = try? Archive(url: file, accessMode: .read, pathEncoding: nil) else { return false }
        return archive.contains { $0.path.hasPrefix("Payload/") && $0.path.contains(".app/") }
    }

    private static let cpu: UInt32 = 0x0100000c
    private static let pageSize = 4096

    private struct Slice {
        let base, offset, size, cryptID: Int
        let subtype: UInt32
    }

    static func decrypt(source: URL, destination: URL, keys: [Data]) throws {
        guard !keys.isEmpty else { throw LabError("请在账户页面导入 FairPlay 凭据。") }
        let input = try Archive(url: source, accessMode: .read)
        var entries = [String: Entry]()
        for entry in input {
            guard entries.updateValue(entry, forKey: entry.path) == nil else {
                throw LabError("IPA 里有重复的文件路径。")
            }
        }
        let manifest = entries.keys.filter { $0.hasSuffix(".supf") && $0.contains("/SC_Info/") }
        var plans = [String: (Entry, Entry)]()
        for path in manifest.sorted() {
            guard let boundary = path.range(of: "/SC_Info/", options: .backwards) else { continue }
            let bundle = String(path[..<boundary.lowerBound])
            let version5 = path.hasSuffix(".v5.supf")
            let file = String(path[boundary.upperBound...].dropLast(version5 ? 8 : 5))
            let binary = bundle + "/" + file
            guard let supf = entries[path], let executable = entries[binary], executable.type == .file else {
                throw LabError("SUPF 对应的可执行文件缺失。")
            }
            if !version5, entries[bundle + "/SC_Info/" + file + ".v5.supf"] != nil { continue }
            let local = entries[bundle + "/SC_Info/" + file + (version5 ? ".v4.sinf" : ".sinf")]
                ?? entries[bundle + "/SC_Info/" + file + ".sinf"]
            let parent = local == nil ? try parentLicense(for: bundle, entries: entries, archive: input) : nil
            guard let sinf = local ?? parent else { continue }
            plans[binary] = (sinf, supf)
        }
        guard !plans.isEmpty else { throw LabError("IPA 缺少受支持的 SINF 和 SUPF 记录。") }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = temporary.appendingPathComponent("result.ipa")
        let output = try Archive(url: result, accessMode: .create)
        let staged = temporary.appendingPathComponent("member")
        var changed = 0
        for entry in input {
            try Task.checkCancellation()
            guard !entry.path.hasPrefix("/"),
                  !entry.path.contains("\\"),
                  !entry.path.split(separator: "/").contains("..") else {
                throw LabError("IPA 包含不安全的文件路径。")
            }
            if entry.type == .directory {
                try output.addEntry(with: entry.path, type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
                continue
            }
            if entry.type == .symlink {
                let target = try read(entry, archive: input, max: 64 * 1024)
                try output.addEntry(with: entry.path, type: .symlink, uncompressedSize: Int64(target.count)) { position, size in
                    target.subdata(in: Int(position)..<(Int(position) + size))
                }
                continue
            }
            guard try input.extract(entry, to: staged) == entry.checksum else {
                throw LabError("IPA 文件 CRC 校验失败。")
            }
            defer { try? FileManager.default.removeItem(at: staged) }
            let plan = plans[entry.path]
            if plan != nil {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            }
            let handle = try plan != nil ? FileHandle(forUpdating: staged) : FileHandle(forReadingFrom: staged)
            defer { try? handle.close() }
            guard let size = Int(exactly: entry.uncompressedSize) else {
                throw LabError("IPA 文件尺寸无效。")
            }
            let file = MachOFile(handle: handle, count: size)
            if let plan {
                let slices = try slices(in: file)
                if !slices.isEmpty {
                    let sinf = try read(plan.0, archive: input, max: 1024 * 1024)
                    let supf = try read(plan.1, archive: input, max: 32 * 1024 * 1024)
                    let work = keys.lazy.compactMap { try? unwrap(sinf, key: $0) }.first
                    guard let work else { throw LabError("FairPlay 凭据与此 IPA 的许可证不匹配。") }
                    try decrypt(file, slices: slices, supf: supf, work: work)
                    changed += 1
                }
            }
            try output.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(size),
                                modificationDate: entry.fileAttributes[.modificationDate] as? Date ?? .now,
                                permissions: entry.fileAttributes[.posixPermissions] as? UInt16,
                                compressionMethod: .deflate) { position, size in
                try Task.checkCancellation()
                return try file.read(at: Int(position), length: size)
            }
        }
        guard changed > 0 else { throw LabError("没有找到需要解密的 arm64 Mach-O。") }
        try FileManager.default.moveItem(at: result, to: destination)
    }

    private static func read(_ entry: Entry, archive: Archive, max: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(max) else { throw LabError("IPA 中的许可证或可执行文件过大。") }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        let crc = try archive.extract(entry) { data.append($0) }
        guard crc == entry.checksum else { throw LabError("IPA 文件 CRC 校验失败。") }
        return data
    }

    private static func parentLicense(for bundle: String, entries: [String: Entry], archive: Archive) throws -> Entry? {
        var parent = bundle
        while let separator = parent.lastIndex(of: "/") {
            parent = String(parent[..<separator])
            guard parent.hasSuffix(".app"), let info = entries[parent + "/Info.plist"] else { continue }
            let bytes = try read(info, archive: archive, max: 4 * 1024 * 1024)
            let plist = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any]
            if let name = plist?["CFBundleExecutable"] as? String {
                if let license = entries[parent + "/SC_Info/" + name + ".v4.sinf"] ?? entries[parent + "/SC_Info/" + name + ".sinf"] {
                    return license
                }
            }
        }
        return nil
    }

    private struct MachOFile {
        let handle: FileHandle
        let count: Int

        func read(at offset: Int, length: Int) throws -> Data {
            guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
                throw LabError("二进制记录超出文件边界。")
            }
            if length == 0 { return Data() }
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: length), bytes.count == length else {
                throw LabError("读取 IPA 文件内容时数据不完整。")
            }
            return bytes
        }

        func write(_ bytes: Data, at offset: Int) throws {
            guard offset >= 0, offset <= count, bytes.count <= count - offset else {
                throw LabError("二进制记录超出文件边界。")
            }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes)
        }

        func uint(_ offset: Int, bytes: Int, big: Bool) throws -> UInt64 {
            try read(at: offset, length: bytes).uint(0, bytes: bytes, big: big)
        }

        func u32(_ offset: Int, big: Bool = false) throws -> UInt32 {
            UInt32(try uint(offset, bytes: 4, big: big))
        }
    }

    private static func slices(in data: MachOFile) throws -> [Slice] {
        let magic = try data.u32(0, big: true)
        var machos = [(Int, Int, UInt32)]()
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(try data.u32(4, big: true))
            let wide = magic == 0xcafebabf
            guard (1...16).contains(count) else { throw LabError("无效的 Fat Mach-O。") }
            for i in 0..<count {
                let start = 8 + i * (wide ? 32 : 20)
                if try data.u32(start, big: true) != cpu { continue }
                let subtype = try data.u32(start + 4, big: true)
                let offset = wide ? try data.uint(start + 8, bytes: 8, big: true) : UInt64(try data.u32(start + 8, big: true))
                let size = wide ? try data.uint(start + 16, bytes: 8, big: true) : UInt64(try data.u32(start + 12, big: true))
                guard offset <= data.count, size <= UInt64(data.count) - offset else { throw LabError("Mach-O 切片越界。") }
                machos.append((Int(offset), Int(size), subtype))
            }
        } else if magic == 0xcffaedfe {
            machos.append((0, data.count, try data.u32(8)))
        } else {
            throw LabError("不支持该 Mach-O 格式。")
        }
        guard !machos.isEmpty else { throw LabError("IPA 不包含 arm64 切片。") }
        return try machos.compactMap { base, length, subtype in
            guard length >= 32 else { throw LabError("无效的 arm64 Mach-O。") }
            let commands = Int(try data.u32(base + 16))
            let end = base + 32 + Int(try data.u32(base + 20))
            guard end <= base + length, commands <= 1000,
                  try data.u32(base) == 0xfeedfacf, try data.u32(base + 4) == cpu else {
                throw LabError("无效的 arm64 Mach-O。")
            }
            var cursor = base + 32
            var found: Slice?
            var seen = false
            for _ in 0..<commands {
                guard end - cursor >= 8 else { throw LabError("Mach-O 加载指令无效。") }
                let command = try data.u32(cursor)
                let size = Int(try data.u32(cursor + 4))
                guard size >= 8, cursor + size <= end else { throw LabError("Mach-O 加载指令无效。") }
                if command == 0x2c {
                    guard !seen, size >= 24 else { throw LabError("Mach-O 加密指令无效。") }
                    seen = true
                    let offset = Int(try data.u32(cursor + 8))
                    let bytes = Int(try data.u32(cursor + 12))
                    let crypt = try data.u32(cursor + 16)
                    if crypt != 0 {
                        guard crypt == 1, bytes > 0, bytes % pageSize == 0,
                              offset + bytes <= length, end <= base + offset else {
                            throw LabError("不支持此 Mach-O 加密区间。")
                        }
                        found = Slice(base: base, offset: offset, size: bytes, cryptID: cursor + 16, subtype: subtype)
                    }
                }
                cursor += size
            }
            guard cursor == end else { throw LabError("Mach-O 加载指令长度不一致。") }
            return found
        }
    }

    private static func field(_ data: Data, _ name: String, in range: Range<Int>) throws -> Range<Int> {
        var cursor = range.lowerBound
        var match: Range<Int>?
        while cursor < range.upperBound {
            let size = Int(try data.u32(cursor, big: true))
            guard size >= 8, cursor + size <= range.upperBound else { throw LabError("许可证记录损坏。") }
            if data.subdata(in: (cursor + 4)..<(cursor + 8)) == Data(name.utf8) {
                guard match == nil else { throw LabError("许可证记录重复。") }
                match = (cursor + 8)..<(cursor + size)
            }
            cursor += size
        }
        guard let match else { throw LabError("许可证缺少必要记录。") }
        return match
    }

    static func credentialMatchesIPA(_ credential: Data, source: URL, member: String) -> Bool {
        guard let archive = try? Archive(url: source, accessMode: .read, pathEncoding: nil), let entry = archive[member],
              let license = try? read(entry, archive: archive, max: 1024 * 1024) else { return false }
        return credentialMatches(credential, license: license)
    }

    static func credentialMatches(_ credential: Data, license: Data) -> Bool {
        (try? unwrap(license, key: credential)) != nil
    }

    private static func unwrap(_ sinf: Data, key: Data) throws -> Data {
        let root = try field(sinf, "sinf", in: 0..<sinf.count)
        guard root == 8..<sinf.count else { throw LabError("无效的 SINF。") }
        let schi = try field(sinf, "schi", in: root)
        let name = sinf.subdata(in: try field(sinf, "name", in: schi)).prefix { $0 != 0 }
        let iv = sinf.subdata(in: try field(sinf, "iviv", in: schi))
        var wrapped = sinf.subdata(in: try field(sinf, "priv", in: schi))
        if wrapped.count == 440, wrapped.suffix(8).allSatisfy({ $0 == 0 }) { wrapped.removeLast(8) }
        guard [432, 448].contains(wrapped.count), iv.count == 16,
              key.count == 16 else { throw LabError("不支持此 SINF 许可证格式。") }
        let work = try aes(wrapped, key: Data(key.map { $0 ^ 48 }),
                           iv: Data(Insecure.MD5.hash(data: Data(name) + iv)))
        guard work.prefix(4) == Data("itun".utf8), work[20..<24] == Data("key ".utf8),
              work[44..<48] == Data("iviv".utf8) else { throw LabError("凭据不匹配。") }
        return work.subdata(in: 24..<40)
    }

    private static func record(_ supf: Data, pages required: Int, subtype: UInt32) throws -> Int {
        guard supf.count >= 12, [3, 5].contains(supf[0]),
              ["507", "510", "612"].contains(String(decoding: supf[1..<4], as: UTF8.self)) else {
            throw LabError("不支持此 SUPF 格式。")
        }
        let header = supf[0] == 3 ? 32 : 12
        let count = Int(try supf.u32(8, big: true))
        guard (1...16).contains(count) else { throw LabError("SUPF 架构数量无效。") }
        var cursor = 12
        for _ in 0..<count {
            let length = Int(try supf.u32(cursor, big: true))
            guard length >= header, cursor + 4 + length <= supf.count else { throw LabError("SUPF 记录损坏。") }
            if try supf.u32(cursor + 4, big: true) == cpu, try supf.u32(cursor + 8, big: true) == subtype {
                let pages = Int(try supf.u32(cursor + header, big: true))
                guard pages >= required, length >= header + pages * 32 else { throw LabError("SUPF 页密钥缺失。") }
                return cursor + 4 + header
            }
            cursor += length + 4
        }
        throw LabError("SUPF 缺少对应的 arm64 切片。")
    }

    private static func decrypt(_ file: MachOFile, slices: [Slice], supf: Data, work: Data) throws {
        let pagesPerBatch = 64
        for slice in slices {
            let count = slice.size / pageSize
            let start = try record(supf, pages: count, subtype: slice.subtype)
            for first in stride(from: 0, to: count, by: pagesPerBatch) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let batchCount = min(pagesPerBatch, count - first)
                    let fileOffset = slice.base + slice.offset + first * pageSize
                    var batch = try file.read(at: fileOffset, length: batchCount * pageSize)
                    for i in 0..<batchCount {
                        let position = start + (first + i) * 32
                        let page = (i * pageSize)..<((i + 1) * pageSize)
                        let offset = fileOffset + page.lowerBound
                        let key = try derive(supf.subdata(in: position..<(position + 16)), index: offset / pageSize, work: work)
                        let clear = try aes(batch.subdata(in: page), key: key, iv: supf.subdata(in: (position + 16)..<(position + 32)))
                        batch.replaceSubrange(page, with: clear)
                    }
                    try file.write(batch, at: fileOffset)
                }
            }
            try file.write(Data(repeating: 0, count: 4), at: slice.cryptID)
        }
    }

    private static func aes(_ data: Data, key: Data, iv: Data?, encrypt: Bool = false) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let length = output.count
        let iv = iv ?? Data()
        let status = output.withUnsafeMutableBytes { dest in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    data.withUnsafeBytes { bytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(iv.isEmpty ? kCCOptionECBMode : 0), keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, bytes.baseAddress, data.count, dest.baseAddress, length, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written == data.count else { throw LabError("AES 处理失败。") }
        return output.prefix(written)
    }

    private static func derive(_ wrapped: Data, index: Int, work: Data) throws -> Data {
        var shifted = (UInt64(index) << 12).bigEndian
        let page = withUnsafeBytes(of: &shifted) { Data($0) }
        let inputs = [Data(wrapped.suffix(8)) + page, wrapped, page + wrapped.prefix(8)]
        let words = try inputs.map { bytes -> [UInt64] in
            let transformed = try aes(bytes, key: work, iv: nil, encrypt: true)
            return try (0..<8).map { try transformed.uint($0 * 2, bytes: 2, big: true) }
        }
        let first = zip(finish(words[0]), words[1]).map(^)
        let second = zip(finish(first), words[2]).map(^)
        return Data(finish(second).flatMap { [UInt8($0 >> 8), UInt8(truncatingIfNeeded: $0)] })
    }

    private static func finish(_ state: [UInt64]) -> [UInt64] {
        let selectors = [[(0,1),(2,3),(4,5),(6,7)], [(2,1),(0,3),(4,7),(6,5)],
                         [(2,0),(4,1),(6,3),(7,5)], [(1,2),(4,0),(7,3),(5,6)]]
        let constants: [UInt64] = [0x68547c2e, 0x7e05e1de, 0xd495038b, 0x0ab24add]
        var src = state
        for round in selectors {
            src = zip(round, constants).flatMap { pair, constant in
                let mixed = src[pair.0] + src[pair.1]
                let x = ((mixed * mixed) & 0xffffffff) ^ (mixed >> 16) ^ constant
                return [x & 0xffff, x >> 16]
            }
        }
        let finalSelectors = [[0,1,2,3], [0,2,4,6], [0,3,5,7], [4,5,6,7]]
        let finalConstants: [UInt64] = [0x5b7198c7, 0xeb5de22c, 0x0f8aa8fa, 0xf6e1bb3f]
        let dst = zip(finalSelectors, finalConstants).flatMap { q, constant in
            let a = (src[q[1]] << 16) | src[q[0]]
            let b = (src[q[3]] << 16) | src[q[2]]
            let mixed = (a + b) & 0xffffffff
            let square = mixed * mixed
            let x = (square & 0xffffffff) ^ (square >> 32) ^ constant
            return [x & 0xffff, x >> 16]
        }
        return zip(state, dst).map(^)
    }
}

private extension Data {
    func uint(_ offset: Int, bytes: Int, big: Bool) throws -> UInt64 {
        guard offset >= 0, offset <= count, bytes <= count - offset else { throw LabError("二进制记录超出文件边界。") }
        var number: UInt64 = 0
        for step in 0..<bytes {
            let index = startIndex + offset + (big ? step : bytes - 1 - step)
            number = (number << 8) | UInt64(self[index])
        }
        return number
    }
    func u32(_ offset: Int, big: Bool = false) throws -> UInt32 {
        UInt32(try uint(offset, bytes: 4, big: big))
    }
}

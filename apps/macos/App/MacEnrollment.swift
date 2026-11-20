import AppKit
import Foundation
import CryptoKit
import ZIPFoundation

struct InstalledMacIOSApp: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: String { url.path }
}

enum MacEnrollment {
    struct Recovered { let data: Data; let selector: String; let verified: Bool; let appName: String }
    struct Reply { let code: Int32; let data: Data; let error: String }
    static func helper(_ resources: URL) -> URL { resources.appendingPathComponent("bin/unfairplay") }
    static func resources() throws -> URL {
        guard let resources = Bundle.main.resourceURL, FileManager.default.isExecutableFile(atPath: helper(resources).path) else { throw LabError("本机 FairPlay 组件缺失，请重新安装完整 Mac 版。") }
        return resources
    }
    static func privateDirectory(parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = parent.appendingPathComponent("IPADecryptEnrollment-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LabError("临时文件已存在，请重试。") }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw LabError("无法写入本机模型文件。") }
    }
    // Output and diagnostics stay in private files; no secrets enter console logs.
    static func run(_ executable: URL, _ arguments: [String], in directory: URL, timeout: TimeInterval = 300) throws -> Reply {
        let output = directory.appendingPathComponent(UUID().uuidString + ".json")
        let error = directory.appendingPathComponent(UUID().uuidString + ".txt")
        try writePrivate(Data(), to: output); try writePrivate(Data(), to: error)
        defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: error) }
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: error)
        defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
        process.standardOutput = out; process.standardError = err
        try Task.checkCancellation(); try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate()
                for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                throw LabError("本机 FairPlay 操作超时，临时文件已清理。")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size < 1_048_576 else { throw LabError("本机组件返回的数据过大。") }
        let errorHandle = try FileHandle(forReadingFrom: error); defer { try? errorHandle.close() }
        let errorData = try errorHandle.read(upToCount: 65_536) ?? Data()
        return Reply(code: process.terminationStatus, data: try Data(contentsOf: output), error: String(data: errorData, encoding: .utf8) ?? "")
    }
    static func object(_ reply: Reply) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else { throw LabError("本机 FairPlay 组件未返回有效结果。") }
        return value
    }
    static func readModel(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, (56...65536).contains(size) else { throw EnrollmentModelFormat.Failure.invalid }
        let data = try Data(contentsOf: url); _ = try EnrollmentModelFormat(data); return data
    }
    static func inspect(_ data: Data, resources: URL) throws -> EnrollmentModelFormat {
        let format = try EnrollmentModelFormat(data), work = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("model.bin"); try writePrivate(data, to: file)
        let reply = try run(helper(resources), ["doctor", "--model", file.path], in: work)
        let result = try object(reply)
        guard reply.code == 0, let models = result["models"] as? [[String: Any]], models.count == 1,
              models[0]["selector_id"] as? String == format.selector else { throw LabError("本机模型格式校验失败，请重新提取或选择有效模型。") }
        return format
    }
    static func normalizedApp(_ url: URL) throws -> URL {
        let outer = url.standardizedFileURL
        guard outer.pathExtension.lowercased() == "app" else { throw LabError("请选择从 Mac App Store 安装的 iPhone 或 iPad App。") }
        let wrapped = outer.appendingPathComponent("WrappedBundle")
        let inner = FileManager.default.fileExists(atPath: wrapped.path) ? wrapped.resolvingSymlinksInPath() : outer
        guard inner.path == outer.path || inner.path.hasPrefix(outer.path + "/Wrapper/"),
              let info = NSDictionary(contentsOf: inner.appendingPathComponent("Info.plist")),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.contains("/"), !executable.contains("\\"), executable != "..",
              FileManager.default.fileExists(atPath: inner.appendingPathComponent("SC_Info/" + executable + ".sinf").path) else {
            throw LabError("此应用没有可用的 iOS FairPlay 许可证。请在原生 Mac App Store 安装并打开一个 iPhone 或 iPad App。")
        }
        return inner
    }
    static func installedApps() -> [InstalledMacIOSApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { url in
                guard (try? normalizedApp(url)) != nil else { return nil }
                return InstalledMacIOSApp(url: url, name: url.deletingPathExtension().lastPathComponent)
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func archiveInstalledApp(_ url: URL, to destination: URL) throws {
        let app = try normalizedApp(url)
        var traversalError: Error?
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in traversalError = error; return false }) else { throw LabError("无法读取所选应用。") }
        let archive = try Archive(url: destination, accessMode: .create)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        while let file = entries.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LabError("所选应用包含符号链接，无法建立可靠的验证包。") }
            if values.isRegularFile == true {
                let relative = String(file.path.dropFirst(app.path.count + 1))
                try archive.addEntry(with: "Payload/" + app.lastPathComponent + "/" + relative, fileURL: file, compressionMethod: .none)
            }
        }
        if let traversalError { throw traversalError }
    }
    static func exportSnapshot(to snapshot: URL, resources: URL, work: URL) throws {
        let command = ["/usr/bin/env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "SUDO_UID=\(getuid())", "SUDO_GID=\(getgid())", helper(resources).path, "export-enrollment", "--output", snapshot.path].map(EnrollmentShell.quote).joined(separator: " ")
        let script = "do shell script " + EnrollmentShell.appleScriptString(command) + " with administrator privileges"
        let reply = try run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], in: work, timeout: 180)
        guard reply.code == 0 else {
            if reply.error.contains("-128") { throw CancellationError() }
            throw LabError("本机注册状态读取失败。请确认已在原生 Mac App Store 登录并打开过 iOS App，且允许本次管理员授权。诊断：mac-enrollment/export")
        }
        guard FileManager.default.fileExists(atPath: snapshot.path) else { throw LabError("本机注册状态尚未生成。") }
    }
    static func recover(app: InstalledMacIOSApp, resources: URL, snapshot: URL? = nil) throws -> Recovered {
        let work = try privateDirectory(); defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent("validation.ipa")
        try archiveInstalledApp(app.url, to: input)
        let enrollment = snapshot ?? work.appendingPathComponent("enrollment.snapshot")
        if snapshot == nil { try exportSnapshot(to: enrollment, resources: resources, work: work) }
        let models = work.appendingPathComponent("models")
        let reply = try run(helper(resources), ["setup", "--enrollment", enrollment.path, "--ipa", input.path, "--model-dir", models.path], in: work)
        guard reply.code == 0 else { throw LabError("无法为所选应用恢复模型。应用许可证可能与本机注册状态不匹配，或注册格式暂不受支持。诊断：mac-enrollment/recover") }
        let result = try object(reply)
        guard result["success"] as? Bool == true, let name = result["model"] as? String else { throw LabError("本机模型恢复未通过完整校验。") }
        let file = URL(fileURLWithPath: name).standardizedFileURL
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == models.resolvingSymlinksInPath().path, file.pathExtension == "bin" else { throw LabError("本机组件返回了无效的模型路径。") }
        let data = try readModel(file), format = try inspect(data, resources: resources)
        return Recovered(data: data, selector: format.selector, verified: result["plaintext_verified"] as? Bool == true, appName: app.name)
    }
    // nil means no authenticated matching model: the caller may use a legacy credential.
    static func decrypt(source: URL, destination: URL, models: [Data], resources: URL) throws -> Bool? {
        guard !models.isEmpty else { return nil }
        let work = try privateDirectory(); defer { try? FileManager.default.removeItem(at: work) }
        let registry = work.appendingPathComponent("models"); try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var unique = Set<Data>()
        for data in models where unique.insert(data).inserted {
            _ = try EnrollmentModelFormat(data)
            try writePrivate(data, to: registry.appendingPathComponent(UUID().uuidString + ".bin"))
        }
        let doctor = try run(helper(resources), ["doctor", "--ipa", source.path, "--model", registry.path], in: work)
        let diagnosis = try object(doctor)
        guard diagnosis["decrypt_ready"] as? Bool == true else { return nil }
        let result = work.appendingPathComponent("decrypted.ipa"), report = work.appendingPathComponent("report.json")
        let reply = try run(helper(resources), ["decrypt", "--input", source.path, "--output", result.path, "--report", report.path, "--model", registry.path], in: work)
        guard reply.code == 0 else { throw LabError("匹配的本机模型未能通过 IPA 解密校验。请确认下载时使用了同一本机注册状态。诊断：mac-enrollment/decrypt") }
        _ = try object(reply)
        let reportSize = (try report.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard reportSize < 8_388_608,
              let response = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any],
              response["schema"] as? String == "unfairplay-decryption-v2", response["complete"] as? Bool == true else { throw LabError("本机模型未返回完整的解密校验报告。") }
        guard FileManager.default.fileExists(atPath: result.path) else { throw LabError("未生成解密后的 IPA。") }
        // Preserve the previous successful artifact if validation or staging fails.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".ipa")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: result, to: staged)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
        return response["plaintext_verified"] as? Bool == true
    }
}

import Foundation

enum Flow: String, CaseIterable, Identifiable {
    case store = "App Store", beta = "TestFlight", local = "本地 IPA"
    var id: String { rawValue }
}

struct DownloadProgress: Equatable {
    var received: Int64 = 0
    var total: Int64 = 0
    var transferring = false
    var preparingPackage = false

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

struct LocalJob: Codable, Identifiable {
    let id: UUID
    let name: String
    let source: String
    var state: State
    var note: String?
    var credentialOwner: String?
    var version: String?
    var storeApp: AppResult?
    var betaBundle: String?
    var originalComplete: Bool?

    var flow: Flow? { Flow(rawValue: source) }
    var needsStoreLicense: Bool {
        flow == .store && note?.hasPrefix("当前账户没有此 App 的授权。") == true
    }
    var retryBetaBundle: String? {
        guard flow == .beta else { return nil }
        return betaBundle ?? (Self.isBundleID(name) ? name : nil)
    }

    static func isBundleID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    // Compatibility: legacy records gain a marker after inspecting the local ZIP directory.
    func recovered(originalIsComplete: Bool) -> LocalJob {
        var copy = self
        copy.originalComplete = originalIsComplete
        if state == .downloading || state == .decrypting {
            copy.state = .failed
            copy.note = originalIsComplete
                ? "上次任务中断，完整原包已保留，可以继续解密。"
                : "上次下载或导入中断，原包不完整，请重新下载或导入。"
        }
        return copy
    }

    enum State: String, Codable {
        case downloading, imported, decrypting, ready, failed
        var title: String {
            switch self {
            case .downloading: return "下载中"
            case .imported: return "原始 IPA 已保存"
            case .decrypting: return "解密中"
            case .ready: return "解密完成"
            case .failed: return "处理未完成"
            }
        }
    }
}


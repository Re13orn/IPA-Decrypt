import Foundation

struct EnrollmentModelFormat: Equatable {
    let version: UInt32
    let selector: String
    init(_ data: Data) throws {
        func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) } }
        guard data.count >= 56 else { throw Failure.invalid }
        let magic = Data(data.prefix(8)), version = word(8)
        let expected = version == 2 ? 4184 : version == 3 ? 8708 : 0
        guard expected != 0, data.count == expected, word(12) == UInt32(data.count),
              magic == Data((version == 2 ? "FPSENR2\0" : "FPSENR3\0").utf8) else { throw Failure.invalid }
        self.version = version
        selector = String(format: "%08x:%08x", word(48), word(52))
    }
    enum Failure: LocalizedError { case invalid; var errorDescription: String? { "请选择受支持的 FairPlay 本机模型文件；16 字节凭据请使用 credential.bin 导入。" } }
}

enum EnrollmentShell {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}

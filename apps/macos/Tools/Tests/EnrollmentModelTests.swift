import Foundation
@main struct EnrollmentModelTests {
    static func main() throws {
        var model = Data(repeating: 0, count: 4184)
        model.replaceSubrange(0..<8, with: Data("FPSENR2\0".utf8))
        func word(_ value: UInt32, at offset: Int) { for i in 0..<4 { model[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) } }
        word(2, at: 8); word(4184, at: 12); word(0x01020304, at: 48); word(2, at: 52)
        let format = try EnrollmentModelFormat(model)
        precondition(format.version == 2 && format.selector == "01020304:00000002")
        for bad in [Data(model.dropLast()), Data(repeating: 0, count: 16), Data(repeating: 0, count: 4184)] {
            do { _ = try EnrollmentModelFormat(bad); fatalError("accepted invalid model") } catch EnrollmentModelFormat.Failure.invalid { }
        }
        var record = FairPlayCredential(data: model, label: "Synthetic model")
        record.kind = "mac-enrollment"; record.enrollmentSelector = format.selector; record.plaintextVerified = true
        let decoded = try JSONDecoder().decode(FairPlayCredential.self, from: JSONEncoder().encode(record))
        precondition(decoded.isEnrollment && decoded.data == model && decoded.plaintextVerified == true)
        precondition(!FairPlayCredential(data: Data(repeating: 0, count: 16)).isEnrollment)
        let hostile = "a'$(touch /tmp/not-executed);\\\"\nb"
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + EnrollmentShell.quote(hostile)]; p.standardOutput = pipe
        try p.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        precondition(p.terminationStatus == 0 && String(data: output, encoding: .utf8) == hostile)
        precondition(EnrollmentShell.appleScriptString("a\"\\\nb") == "\"a\\\"\\\\\\nb\"")
        print("PASS enrollment envelope rejection, metadata migration, literal administrator argument escaping")
    }
}

import Foundation
import MacBridge

extension StoreRuntime {
    static func checkEngine() throws {
        guard let resources = Bundle.main.resourceURL else { throw Failure.missing }
        _ = try prepare(resources: resources)
        let data: Data = try #"{"operation":"runtime-check"}"#.withCString { request in
            guard let output = IPAToolCall(UnsafeMutablePointer(mutating: request)) else { throw Failure.engine("runtime-check/bridge") }
            defer { IPAToolFree(output) }
            return Data(String(cString: output).utf8)
        }
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard result?["error"] as? Bool != true, result != nil else {
            let allowed = ["login/unicorn-link", "login/unicorn-execution", "login/unicorn-executable-memory"]
            let code = result?["diagnostic"] as? String ?? ""
            throw Failure.engine(allowed.contains(code) ? code : "runtime-check/failed")
        }
    }

}

import Foundation

struct Beta: Identifiable {
    let id, name: String

    static func catalog(_ data: Data) throws -> [Beta] {
        var found: [String: Beta] = [:]
        func visit(_ value: Any, appID: String? = nil, name: String? = nil) {
            if let list = value as? [Any] { for item in list { visit(item, appID: appID, name: name) }; return }
            guard let info = value as? [String: Any] else { return }
            let localID = ["appAdamId", "adamId", "appId"].compactMap { key -> String? in
                guard let value = info[key] else { return nil }
                if let string = value as? String, !string.isEmpty { return string }
                return (value as? NSNumber)?.stringValue
            }.first
            let ownID = localID ?? appID
            let ownName = ["appName", "name", "title"].compactMap { info[$0] as? String }.first
            let title = localID != nil || appID == nil ? ownName ?? name : name ?? ownName
            if let bundle = (info["bundleId"] ?? info["bundleIdentifier"]) as? String,
               bundle.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil, ownID != nil {
                found[bundle] = Beta(id: bundle, name: title ?? bundle)
            }
            for child in info.values { visit(child, appID: ownID, name: title) }
        }
        visit(try JSONSerialization.jsonObject(with: data))
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}


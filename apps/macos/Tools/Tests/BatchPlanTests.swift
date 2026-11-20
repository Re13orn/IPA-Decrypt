import Foundation
@main struct BatchPlanTests {
    static func main() throws {
        func item(_ name: String, supported: Bool = true, match: String? = nil) -> InstalledLicense {
            InstalledLicense(path: name, appName: name, bundleID: "test." + name, user: "01020304", key: "00000002", digest: "", reason: "", supported: supported, credentialMatch: match)
        }
        var licenses = [item("existing",match:"key-A"),item("extension",supported:false),item("fail"),item("succeed"),item("duplicate")]
        var plan = CredentialBatchPlan()
        precondition(plan.next(in: licenses)?.id == "fail")
        plan.attempted.insert("fail");plan.failures["fail"]="fixture failure"
        precondition(plan.next(in: licenses)?.id == "succeed")
        plan.attempted.insert("succeed")
        // One successful extraction can cover failed and not-yet-attempted sources.
        for i in 2..<licenses.count { licenses[i].credentialMatch="key-B" }
        plan.reconcile(licenses)
        precondition(plan.next(in: licenses) == nil && plan.failures.isEmpty)
        let groups = InstalledCredentialGroup.make(licenses)
        precondition(groups.filter { $0.credentialID != nil }.count == 2)
        precondition(groups.first { $0.credentialID == "key-B" }?.members.count == 3)
        let encoded = try JSONEncoder().encode(CredentialProbe(id:"key-A",data:Data(repeating:1,count:16)))
        precondition(!encoded.isEmpty)
        print("PASS batch planning: skip verified/unsupported, continue after failure, reuse new keys, reconcile covered failures and exact result counts")
    }
}

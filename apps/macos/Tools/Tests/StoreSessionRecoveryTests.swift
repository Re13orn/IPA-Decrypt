import Foundation
@main struct StoreSessionRecoveryTests {
    enum Failure: Error { case credentials, transport }
    @MainActor static func main() async throws {
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0
            let response=try await recovery.perform(owner:"A",initiallyExpired:false,authenticate:{refreshes+=1},request:{requests+=1;return "ok"},isExpired:{$0=="expired"})
            precondition(response=="ok" && refreshes==0 && requests==1)
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0
            let response=try await recovery.perform(owner:"A",initiallyExpired:false,authenticate:{refreshes+=1},request:{requests+=1;return requests==1 ? "expired":"ok"},isExpired:{$0=="expired"})
            precondition(response=="ok" && refreshes==1 && requests==2)
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0
            let response=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1},request:{requests+=1;return "expired"},isExpired:{$0=="expired"})
            precondition(response=="expired" && refreshes==1 && requests==1 && recovery.isBlocked("A"))
            do { let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1},request:{requests+=1;return "ok"},isExpired:{$0=="expired"});preconditionFailure() }
            catch { precondition(refreshes==1 && requests==1) }
            recovery.reset("A")
            let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1},request:{requests+=1;return "ok"},isExpired:{$0=="expired"})
            precondition(refreshes==2 && requests==2)
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0
            do { let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1;throw Failure.credentials},request:{requests+=1;return "ok"},isExpired:{$0=="expired"});preconditionFailure() }
            catch { precondition(recovery.isBlocked("A") && refreshes==1 && requests==0) }
            precondition(!recovery.isBlocked("B"))
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0
            do { let _:String=try await recovery.perform(owner:"A",initiallyExpired:false,authenticate:{refreshes+=1},request:{throw Failure.transport},isExpired:{$0=="expired"});preconditionFailure() }
            catch { precondition(refreshes==0 && !recovery.isBlocked("A")) }
        }
        do {
            let recovery=StoreSessionRecovery()
            do { let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{throw StoreRecoveryFailure.passwordUnavailable},request:{"not-called"},isExpired:{$0=="expired"});preconditionFailure() }
            catch { precondition(!recovery.isBlocked("A")) }
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0
            let authenticate: @MainActor () async throws -> Void = {refreshes+=1;try await Task.sleep(nanoseconds:30_000_000)}
            let first=Task { try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:authenticate,request:{requests+=1;return "ok"},isExpired:{$0=="expired"}) }
            let second=Task { try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:authenticate,request:{requests+=1;return "ok"},isExpired:{$0=="expired"}) }
            _=try await(first.value,second.value)
            precondition(refreshes==1 && requests==2)
        }
        do {
            let recovery=StoreSessionRecovery();var requests=0
            let pending=Task { try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{try await Task.sleep(nanoseconds:30_000_000)},request:{requests+=1;return "ok"},isExpired:{$0=="expired"}) }
            pending.cancel()
            do { _=try await pending.value;preconditionFailure() } catch { precondition(requests==0) }
        }
        do {
            let recovery=StoreSessionRecovery();var submitted=false,code:String?
            let pending=Task { try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{
                while code == nil { try await Task.sleep(nanoseconds:1_000_000) }
            },request:{submitted=true;return "ok"},isExpired:{$0=="expired"}) }
            try await Task.sleep(nanoseconds:5_000_000);precondition(!submitted)
            code="123456";_=try await pending.value;precondition(submitted)
        }
        for diagnostic in ["login/bag-auth-endpoint", "login/store-runtime", "login/store-framework", "login/endpoint", "login/request HTTP 404, 204, 404", "login/request HTTP 503"] {
            precondition(StoreAuthenticationRetryPolicy.permits(diagnostic:diagnostic,requiresAccountAction:false))
            precondition(!StoreAuthenticationRetryPolicy.permits(diagnostic:diagnostic,requiresAccountAction:true))
        }
        for diagnostic in ["login/request Apple -5000", "login/request HTTP 429", "login/request HTTP 503, 429", "login/verification", "login/2fa-required", "login/request HTTP 401", "login/request HTTP 403", "login/request", "login/request HTTP", "login/request HTTP 503,", "testflight-auth/endpoint"] {
            precondition(!StoreAuthenticationRetryPolicy.permits(diagnostic:diagnostic,requiresAccountAction:false))
        }
        precondition(!StoreAuthenticationRetryPolicy.permits(diagnostic:nil,requiresAccountAction:false))
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0,waits=0
            let value=try await recovery.perform(owner:"A",initiallyExpired:false,authenticate:{
                refreshes+=1;if refreshes==1 { throw Failure.transport }
            },retryAuthentication:{ if case Failure.transport = $0 { return true };return false },pauseBeforeRetry:{waits+=1},
              request:{requests+=1;return requests==1 ? "expired":"ok"},isExpired:{$0=="expired"})
            precondition(value=="ok" && refreshes==2 && requests==2 && waits==1 && !recovery.isBlocked("A"))
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,requests=0
            do {
                let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1;throw Failure.transport},
                    retryAuthentication:{_ in true},pauseBeforeRetry:{},request:{requests+=1;return "ok"},isExpired:{$0=="expired"})
                preconditionFailure()
            } catch { precondition(refreshes==2 && requests==0 && recovery.isBlocked("A")) }
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0
            do {
                let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1;throw Failure.credentials},
                    retryAuthentication:{_ in false},pauseBeforeRetry:{preconditionFailure()},request:{"ok"},isExpired:{$0=="expired"})
                preconditionFailure()
            } catch { precondition(refreshes==1 && recovery.isBlocked("A")) }
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0
            do {
                let _:String=try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1;throw Failure.transport},
                    retryAuthentication:{_ in true},pauseBeforeRetry:{throw CancellationError()},request:{"ok"},isExpired:{$0=="expired"})
                preconditionFailure()
            } catch is CancellationError { precondition(refreshes==1 && !recovery.isBlocked("A")) }
        }
        do {
            let recovery=StoreSessionRecovery();var refreshes=0,waits=0,requests=0
            func operation() async throws -> String {
                try await recovery.perform(owner:"A",initiallyExpired:true,authenticate:{refreshes+=1;if refreshes==1 {throw Failure.transport}},
                    retryAuthentication:{_ in true},pauseBeforeRetry:{waits+=1;try await Task.sleep(nanoseconds:10_000_000)},
                    request:{requests+=1;return "ok"},isExpired:{$0=="expired"})
            }
            let first=Task { try await operation() };let second=Task { try await operation() }
            _=try await(first.value,second.value)
            precondition(refreshes==2 && waits==1 && requests==2)
        }
        print("PASS Store recovery: existing session/expiry/reset/isolation/verification checks; allowlisted transient retry once; bad credentials, verification, restrictions and rate limits excluded; bounded failures, cancellation and concurrent retry coalescing")
    }
}

import SwiftUI

/// Selects an existing session for one service; adding and reauthentication stay in account management.
@MainActor struct ServiceAccountMenu: View {
    @ObservedObject var model: LocalLab
    let beta: Bool
    var compact = false
    let manage: () -> Void
    private var service: String { beta ? "TestFlight" : "App Store" }
    private var profiles: [AppleProfile] { beta ? model.accounts.beta : model.accounts.store }
    private var active: AppleProfile? { model.activeProfile(beta: beta) }

    var body: some View {
        Group {
            if profiles.isEmpty {
                Button(action: manage) { accountLabel }.buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(profiles) { profile in
                        Button {
                            do {
                                try model.switchAccount(profile.id, beta: beta)
                                if profile.needsReauth == true { manage() }
                            } catch { model.message = model.friendly(error) }
                        } label: {
                            Label(profile.email + (profile.needsReauth == true ? " · 需重新登录" : ""),
                                  systemImage: active?.id == profile.id ? "checkmark.circle.fill" : "person.crop.circle")
                        }
                    }
                    Divider()
                    Button("管理 \(service) 账户…", systemImage: "person.crop.circle.badge.plus", action: manage)
                } label: { accountLabel }
            }
        }
        .disabled(model.action != nil || model.automaticStoreLoginStatus != nil)
        .accessibilityLabel(service + " 下载账户，" + (active?.email ?? "未选择"))
        .accessibilityHint("切换此服务的账户，不影响另一个服务")
    }
    private var accountLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: beta ? "paperplane" : "person.crop.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(service + " · " + (active?.email ?? "选择或登录账户"))
                .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if !compact { Spacer(minLength: 4) }
            if active?.needsReauth == true {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("需要重新登录")
            }
            #if os(iOS)
            Image(systemName: profiles.isEmpty ? "chevron.right" : "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            #endif
        }
        .frame(maxWidth: compact ? 280 : .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(service + " 下载账户：" + (active?.email ?? "未选择") + "；点击切换或管理")
    }
}

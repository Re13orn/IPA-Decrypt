import AppKit
import SwiftUI

/// Nested sheets (for example, credential import) belong to child views, so
/// workspace commands must also respect the actual window's modal state.
@MainActor private final class MacCommandContext: ObservableObject {
    static let shared = MacCommandContext()
    @Published private(set) var modal = false
    private var observers: [NSObjectProtocol] = []

    static var hasModal: Bool {
        NSApp.modalWindow?.isVisible == true || NSApp.keyWindow?.sheetParent != nil ||
            NSApp.keyWindow?.attachedSheet?.isVisible == true || NSApp.mainWindow?.attachedSheet?.isVisible == true
    }
    private init() {
        for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Sheet notifications can arrive before AppKit updates attachedSheet.
                DispatchQueue.main.async {
                    guard let self else { return }
                    let value = Self.hasModal
                    if self.modal != value { self.modal = value }
                }
            })
        }
        modal = Self.hasModal
    }
}

struct MacWorkspaceActions {
    let navigate: (MacPage) -> Void
    let find: () -> Void
    let refresh: () -> Void
    let importIPA: () -> Void
    let canNavigate: Bool
    let canRefresh: Bool
    let canImport: Bool
}

private struct MacWorkspaceActionsKey: FocusedValueKey {
    typealias Value = MacWorkspaceActions
}

extension FocusedValues {
    var macWorkspaceActions: MacWorkspaceActions? {
        get { self[MacWorkspaceActionsKey.self] }
        set { self[MacWorkspaceActionsKey.self] = newValue }
    }
}

@MainActor struct MacWorkspaceCommands: Commands {
    @FocusedValue(\.macWorkspaceActions) private var actions
    @ObservedObject private var context = MacCommandContext.shared

    private var modal: Bool {
        // Read AppKit again when actions change: runModal can finish between
        // window notifications, before the observer gets its next update.
        _ = context.modal
        return MacCommandContext.hasModal
    }
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("导入 IPA…") { if !MacCommandContext.hasModal { actions?.importIPA() } }
                .keyboardShortcut("o").disabled(modal || actions?.canImport != true)
        }
        CommandGroup(after: .textEditing) {
            Button("查找…") { if !MacCommandContext.hasModal { actions?.find() } }
                .keyboardShortcut("f").disabled(modal || actions?.canNavigate != true)
        }
        CommandMenu("前往") {
            ForEach(Array(MacPage.allCases.enumerated()), id: \.element.id) { index, page in
                Button(page.rawValue) { if !MacCommandContext.hasModal { actions?.navigate(page) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(modal || actions?.canNavigate != true)
            }
            Divider()
            Button("刷新") { if !MacCommandContext.hasModal { actions?.refresh() } }
                .keyboardShortcut("r").disabled(modal || actions?.canRefresh != true)
        }
    }
}

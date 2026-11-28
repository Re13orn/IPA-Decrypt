import SwiftUI

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

struct MacWorkspaceCommands: Commands {
    @FocusedValue(\.macWorkspaceActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("导入 IPA…") { actions?.importIPA() }
                .keyboardShortcut("o").disabled(actions?.canImport != true)
        }
        CommandGroup(after: .textEditing) {
            Button("查找…") { actions?.find() }
                .keyboardShortcut("f").disabled(actions?.canNavigate != true)
        }
        CommandMenu("前往") {
            ForEach(Array(MacPage.allCases.enumerated()), id: \.element.id) { index, page in
                Button(page.rawValue) { actions?.navigate(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(actions?.canNavigate != true)
            }
            Divider()
            Button("刷新") { actions?.refresh() }
                .keyboardShortcut("r").disabled(actions?.canRefresh != true)
        }
    }
}

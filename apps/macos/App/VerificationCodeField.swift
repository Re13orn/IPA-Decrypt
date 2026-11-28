import SwiftUI

/// One native text field preserves paste, AutoFill, selection and deletion across all six slots.
struct VerificationCodeField: View {
    @Binding var code: String
    var submit: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .title2) private var digitSize = 27

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.plain)
                .font(.system(size: digitSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.clear).tint(.clear)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("6 位验证码")
                .accessibilityHint("可输入或粘贴完整验证码")
                .onSubmit { if code.count == 6 && enabled { submit() } }
            HStack(spacing: 8) {
                ForEach(0..<6) { index in
                    if index == 3 { Spacer().frame(width: 4) }
                    Text(digit(at: index))
                        .font(.system(size: digitSize, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(.background, in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(focused && index == min(code.count, 5) ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused && index == min(code.count, 5) ? 2 : 1)
                        }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(height: 58).frame(maxWidth: 340)
        .onChange(of: code) { value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != value { code = digits }
        }
        .task { await Task.yield(); focused = true }
        .onChange(of: enabled) { value in if value { focused = true } }
    }

    private func digit(at index: Int) -> String {
        let digits = Array(code)
        return digits.indices.contains(index) ? String(digits[index]) : " "
    }
}

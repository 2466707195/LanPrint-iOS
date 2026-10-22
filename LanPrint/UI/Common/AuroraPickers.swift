import SwiftUI

// === Aurora UI 表单控件（局域网打印）===

/// 带标题的表单块。
struct LabeledField<Content: View>: View {

    let title: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AuroraFont.labelMedium)
                .foregroundStyle(Aurora.inkSoft)
            content()
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(Aurora.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 白底下拉选择框（对应 Android 的 DropdownField）。
struct MenuField<Option: Hashable>: View {

    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    var hint: String? = nil

    var body: some View {
        LabeledField(title: title, hint: hint) {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(label(selection))
                        .font(AuroraFont.bodyMedium)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .background(AuroraShape.control.fill(Color.white))
                .overlay(
                    AuroraShape.control.stroke(Aurora.line, lineWidth: 1)
                )
                .contentShape(AuroraShape.control)
            }
        }
    }
}

/// 胶囊分段选择器。
struct AuroraSegmented<Option: Hashable>: View {

    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(AuroraFont.labelLarge)
                        .foregroundStyle(selected ? Color.white : Aurora.inkSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            Capsule().fill(selected ? Aurora.brand : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(Aurora.line.opacity(0.8), lineWidth: 1))
    }
}

/// 数量步进器（份数）。
struct CountStepper: View {

    @Binding var value: Int
    var range: ClosedRange<Int> = 1...99

    var body: some View {
        HStack(spacing: 12) {
            stepButton(system: "minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - 1)
            }
            Text("\(value)")
                .font(AuroraFont.titleMedium)
                .foregroundStyle(Aurora.ink)
                .frame(minWidth: 34)
            stepButton(system: "plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + 1)
            }
        }
    }

    private func stepButton(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Aurora.brand : Aurora.muted)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(enabled ? Aurora.brandContainer : Aurora.surfaceVariant)
                )
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .disabled(!enabled)
    }
}

/// 表单里的一行说明（图标 + 文字）。
struct InfoRow: View {

    let systemIcon: String
    let text: String
    var color: Color = Aurora.inkSoft

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

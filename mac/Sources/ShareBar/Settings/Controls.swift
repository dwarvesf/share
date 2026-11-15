import ShareBarCore
import SwiftUI

enum SBButtonKind { case normal, primary, destructiveFill, destructiveText }

/// The prototype's `.btn`: 13 pt medium, 6 pt radius, a 1 px border; primary is the info fill.
struct SBButtonStyle: ButtonStyle {
    var kind: SBButtonKind = .normal
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let t = SettingsTheme(scheme)
        let fill: Color
        let ink: Color
        let border: Color
        switch kind {
        case .normal: fill = t.field; ink = t.label; border = t.border
        case .primary: fill = t.color(Tokens.palette(scheme == .dark ? .dark : .light).semantic.info); ink = .white; border = fill
        case .destructiveFill: fill = t.destructiveFill; ink = .white; border = fill
        case .destructiveText: fill = t.field; ink = t.errorInk; border = t.border
        }
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(ink)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? fill.opacity(0.8) : fill))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension View {
    func sbButton(_ kind: SBButtonKind = .normal) -> some View { buttonStyle(SBButtonStyle(kind: kind)) }
}

/// A one-line text field with a placeholder whose color is set (a SwiftUI prompt ignores its color).
struct SBField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var id = ""
    var onSubmit: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        let t = SettingsTheme(scheme)
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).font(mono ? t.monoFont : t.bodyFont).foregroundColor(t.tertiary).allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(mono ? t.monoFont : t.bodyFont)
                .foregroundColor(t.label)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier(id)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? t.focus : t.softBorder, lineWidth: focused ? 2 : 1))
    }
}

/// A secure field for the asked key (gap G3): same look, bullets, no placeholder leak.
struct SBSecureField: View {
    let placeholder: String
    @Binding var text: String
    var id = ""
    var onSubmit: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        let t = SettingsTheme(scheme)
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder).font(t.bodyFont).foregroundColor(t.tertiary).allowsHitTesting(false)
            }
            SecureField("", text: $text)
                .textFieldStyle(.plain)
                .font(t.bodyFont)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier(id)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? t.focus : t.softBorder, lineWidth: focused ? 2 : 1))
    }
}

/// The prototype's `.seg2`: a rounded track, the selected segment a raised field.
struct SBSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var small = false
    var idPrefix = "seg"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: small ? 11 : 13, weight: .medium))
                        .foregroundColor(t.label)
                        .frame(maxWidth: small ? nil : .infinity)
                        .padding(.horizontal, small ? 10 : 5).padding(.vertical, small ? 4 : 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? t.field : .clear)
                            .shadow(color: .black.opacity(on ? 0.14 : 0), radius: 1, y: 1))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? t.separator : .clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix)-\(option.1.lowercased().replacingOccurrences(of: " ", with: "-"))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(t.hover))
        .fixedSize(horizontal: small, vertical: false)
    }
}

/// A native pop-up button styled to the field look.
struct SBPopup<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var id = ""
    var fullWidth = false

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.1).tag(option.0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .fixedSize(horizontal: !fullWidth, vertical: false)
        .accessibilityIdentifier(id)
    }
}

/// A small spinner drawn as a ring, so a captured frame always shows it.
struct SBSpinner: View {
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme
    @State private var angle = 0.0

    var body: some View {
        let t = SettingsTheme(scheme)
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(t.focus, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .background(Circle().stroke(t.separator, lineWidth: 2))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { angle = 360 } }
            .accessibilityLabel("Working")
    }
}

/// Status dot of the tenant detail: filled green, hollow quiet, a spinner while starting.
struct StatusMark: View {
    let tone: TenantStatusTone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = SettingsTheme(scheme)
        switch tone {
        case .ok: Circle().fill(t.ok).frame(width: 7, height: 7)
        case .spinner: SBSpinner(size: 10)
        case .quiet: Circle().stroke(t.tertiary, lineWidth: 1.5).frame(width: 7, height: 7)
        case .attention: Circle().fill(t.attention).frame(width: 7, height: 7)
        }
    }
}

/// A rectangle with its top corners, or its bottom corners, rounded (macOS 13 has no
/// `UnevenRoundedRectangle`).
struct EdgeRounded: Shape {
    enum Edge { case top, bottom }
    let edge: Edge
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.height / 2, rect.width / 2)
        switch edge {
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
        return path
    }
}

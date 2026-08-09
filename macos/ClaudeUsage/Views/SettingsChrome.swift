import SwiftUI

/// Layout primitives for the Settings window.
///
/// Deliberately not `Form { }.formStyle(.grouped)`. That gets you the stock look for free,
/// but it also ignores every token the rest of the app uses, leans on `.secondary` for
/// labels — which is the mud problem the popover had in dark mode — and gives no control
/// over row rhythm. These four types cost little and keep Settings in the same language as
/// the panel.

/// A titled group of rows on one card.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(DS.eyebrow)
                .kerning(DS.eyebrowKerning)
                .foregroundStyle(DS.inkFaint)

            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(DS.hairline, lineWidth: 1)
                )

            if let footnote {
                Text(footnote)
                    .font(DS.label(10.5))
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }
}

/// One row: a label on the left, a control on the right, an optional explanation beneath.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var isEnabled: Bool = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.label(12))
                    .foregroundStyle(isEnabled ? DS.ink : DS.inkFaint)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.label(10.5))
                        .foregroundStyle(DS.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
                .labelsHidden()
                .controlSize(.small)
                .disabled(!isEnabled)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }
}

/// A row whose right-hand side is read-only text rather than a control.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(DS.label(12))
                .foregroundStyle(DS.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(DS.figure(11))
                .foregroundStyle(tint ?? DS.inkMuted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }
}

/// Hairline between rows on the same card, inset so it doesn't touch the card edge.
struct RowRule: View {
    var body: some View {
        Rectangle()
            .fill(DS.hairline)
            .frame(height: 1)
            .padding(.leading, 11)
    }
}

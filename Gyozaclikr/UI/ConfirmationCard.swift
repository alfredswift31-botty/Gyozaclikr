import SwiftUI

/// The confirmation card (docs/DESIGN.md "Confirmation"): the action's
/// title, every argument in words in two columns, Edit and the action.
/// Shown inside the box for mail, reminders, events, notes and shortcuts.
struct ConfirmationCard: View {
    let proposal: ActionProposal
    var onEdit: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        let rows = ConfirmationRows.rows(for: proposal)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(proposal.title)
                .font(BoxFont.bodyMedium)
                .foregroundStyle(BoxColor.ink)
            Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                ForEach(rows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .labelStyle()
                            .frame(width: 56, alignment: .leading)
                            .padding(.top, 2)
                        Text(row.value)
                            .font(BoxFont.body)
                            .foregroundStyle(BoxColor.ink)
                            .lineLimit(row.lines)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                QuietButton(title: "Edit", action: onEdit)
                PrimaryButton(title: ConfirmationRows.verb(for: proposal), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ConfirmationRows.spoken(proposal))
    }
}

/// The one filled button: ink on the card, the box's primary action.
struct PrimaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BoxFont.small.weight(.medium))
                .foregroundStyle(Theme.inkInverse)
                .padding(.horizontal, 10)
                .frame(height: Theme.Box.chipHeight)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
    }
}

/// Text-only buttons for the rest of the row.
struct QuietButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BoxFont.small)
                .foregroundStyle(BoxColor.ink)
                .padding(.horizontal, Theme.Space.s)
                .frame(height: Theme.Box.chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A 24-pt chip with a hairline outline; the suggested one glows at 40 %
/// accent (the one static glow docs/DESIGN.md allows). Increase Contrast
/// makes outlines solid.
struct ChipButton: View {
    let title: String
    var suggested = false
    var hint: String?
    var action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let strong = contrast == .increased
        Button(action: action) {
            Text(title)
                .font(BoxFont.small)
                .foregroundStyle(BoxColor.ink)
                .padding(.horizontal, 10)
                .frame(height: Theme.Box.chipHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(suggested ? BoxColor.accent.opacity(strong ? 1 : 0.4) : (strong ? BoxColor.secondary : BoxColor.hairline),
                                      lineWidth: strong ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint ?? "")
    }
}

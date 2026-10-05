import SwiftUI

/// Renders `MarkdownLite` blocks the way the box wants them: paragraphs
/// with bold runs, bullets with a dot, numbers in mono, fenced code in mono
/// inside a hairline box. No colours beyond ink and the hairline.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownLite.parse(text)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MarkdownLite.plainText(text))
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownLite.Block) -> some View {
        switch block {
        case .paragraph(let runs):
            Self.text(runs)
                .font(BoxFont.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text("•").font(BoxFont.body).foregroundStyle(.secondary).frame(width: 8, alignment: .trailing)
                        Self.text(item.inlines).font(BoxFont.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * Theme.Space.l)
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text("\(item.number ?? index + 1).").font(BoxFont.mono).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                        Self.text(item.inlines).font(BoxFont.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * Theme.Space.l)
                }
            }
        case .code(let code):
            Text(code)
                .font(BoxFont.mono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(BoxColor.hairline))
        }
    }

    /// One `Text` from the runs, so bold and code flow inside a line.
    static func text(_ runs: [MarkdownLite.Inline]) -> Text {
        runs.reduce(Text("")) { result, run in
            switch run {
            case .text(let s): result + Text(s)
            case .bold(let s): result + Text(s).fontWeight(.semibold)
            case .code(let s): result + Text(s).font(BoxFont.mono)
            }
        }
    }
}

/// The box's colours: the system's semantic ones, so dark, light and the
/// user's accent come for free (docs/DESIGN.md "Dark, light, accessibility").
enum BoxColor {
    static let hairline = Color(nsColor: .separatorColor)
    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color.accentColor
    /// Opaque fallback for the material (Reduce Transparency, snapshots).
    static let opaque = Color(nsColor: .windowBackgroundColor)
}

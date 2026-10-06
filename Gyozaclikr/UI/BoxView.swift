import SwiftUI

/// The card (docs/DESIGN.md): the selection preview, the input, the chip
/// row, and in turn the engine label, the status word with its accent
/// bar, the streamed answer, the action row, a failure sentence, a
/// question with option chips, or the confirmation card. 360 pt wide,
/// 480 while an answer is on screen; the panel follows its height.
struct BoxView: View {
    let model: BoxModel
    /// Hands the input field to the panel for first responder.
    var registerInput: ((InputField) -> Void)?
    /// Reports the card's rendered size, so the panel can follow it exactly.
    var onSize: ((CGSize) -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.boxOpaque) private var opaque
    @Environment(\.boxAnimates) private var animates

    var body: some View {
        let hairline: CGFloat = contrast == .increased ? 1.5 : 1
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SelectionPreview(selection: model.selection)
            switch model.state {
            case .hidden, .empty, .typing:
                input
                chipRow
            case .streaming:
                thread
                EngineRow(label: model.engineLabel)
                StatusLine(status: model.status, elapsed: model.engine == .ollama ? model.elapsed : nil,
                           full: !model.answer.isEmpty, reduceMotion: animates.map { !$0 } ?? reduceMotion)
                input
            case .done:
                thread
                EngineRow(label: model.engineLabel)
                extractionNote
                ActionRow(model: model)
                if let outcome = model.outcome { OutcomeLine(outcome: outcome) }
                input
            case .failed:
                if !model.turns.isEmpty { thread }
                FailureLine(model: model)
                input
            case .confirming:
                if let proposal = model.proposal {
                    ConfirmationCard(proposal: proposal, onEdit: { model.edit() }, onConfirm: { model.onConfirm(proposal) })
                }
            case .asking:
                if !model.turns.isEmpty { thread }
                AskingLine(question: model.question, options: model.options, onOption: model.onOption)
                input
            }
        }
        .padding(Theme.Box.padding)
        .frame(width: model.width, alignment: .topLeading)
        .background(chrome)
        .overlay(alignment: .top) {
            if model.engine == .ollama, model.state.isWide {
                Theme.engineGradient.frame(height: 2).accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Box.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Box.radius).strokeBorder(BoxColor.hairline, lineWidth: hairline))
        .overlay(alignment: .topTrailing) {
            Button { model.onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BoxColor.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Close")
            .keyboardShortcut("w", modifiers: .command)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityTitle)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in onSize?(size) }
    }

    @ViewBuilder
    private var chrome: some View {
        if opaque || reduceTransparency {
            BoxColor.opaque
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    private var input: some View {
        BoxInput(model: model, register: registerInput)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Ask")
    }

    private var chipRow: some View {
        let suggestion = model.activeSuggestion
        return ChipFlow(spacing: Theme.Box.chipSpacing) {
            ForEach(model.visibleChips, id: \.self) { chip in
                ChipButton(title: chip.title, suggested: chip == suggestion, hint: "Command \(chip.shortcut)") {
                    model.onChip(chip)
                }
            }
        }
    }

    /// The conversation: each request in the secondary colour, its answer
    /// below, a hairline between turns. Scrolls past 300 pt and follows the
    /// live answer. The whole thread is the "answer" the owner reads.
    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(model.turns.enumerated()), id: \.element.id) { index, turn in
                        if index > 0 { Rectangle().fill(BoxColor.hairline).frame(height: 1) }
                        Text(turn.request)
                            .font(BoxFont.body)
                            .foregroundStyle(BoxColor.secondary)
                            .textSelection(.enabled)
                        if let failure = turn.failure {
                            Text(failure)
                                .font(BoxFont.body)
                                .foregroundStyle(BoxColor.secondary)
                        } else if !turn.answer.isEmpty {
                            MarkdownView(text: turn.answer)
                                .textSelection(.enabled)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.answer) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.turns.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var extractionNote: some View {
        if model.answerKind == .extraction, model.dropped > 0 {
            Text("\(model.kept) kept · \(model.dropped) dropped: no quote in the selection")
                .font(BoxFont.mono)
                .foregroundStyle(BoxColor.tertiary)
        }
    }
}

// MARK: - Pieces

/// The selection: a two-line quote with a left rule and the token count,
/// or a 48-pt thumbnail with the OCR word count. Nothing for a word.
struct SelectionPreview: View {
    let selection: Selection

    var body: some View {
        switch selection.kind {
        case .text:
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Rectangle().fill(BoxColor.hairline).frame(width: 1)
                Text(selection.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    .font(BoxFont.body)
                    .foregroundStyle(BoxColor.secondary)
                    .lineLimit(Theme.Box.quoteLines)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let tokens = selection.tokenEstimate {
                    Text("\(tokens) tok")
                        .font(BoxFont.mono)
                        .foregroundStyle(BoxColor.tertiary)
                        .padding(.top, 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case .image:
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                if let image = selection.image.flatMap({ NSImage(data: $0.png) }) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: Theme.Box.thumbnailHeight)
                        .overlay(Rectangle().strokeBorder(BoxColor.hairline))
                        .accessibilityLabel("Selected image")
                }
                if let words = selection.ocrWordCount {
                    Text("OCR · \(words) words")
                        .font(BoxFont.mono)
                        .foregroundStyle(BoxColor.tertiary)
                }
                Spacer(minLength: 0)
            }
        case .word, .none:
            EmptyView()
        }
    }
}

/// The collapsed chip row while the engine works: the engine's name.
struct EngineRow: View {
    let label: String

    var body: some View {
        Text(label)
            .font(BoxFont.small)
            .foregroundStyle(BoxColor.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The status word and the 2-pt accent bar under it, filling over the
/// first-token second; a static dot under Reduce Motion. Elapsed seconds
/// in mono on the Ollama path.
struct StatusLine: View {
    let status: String
    var elapsed: TimeInterval?
    /// Full once the first token arrived.
    var full: Bool
    var reduceMotion: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(status)
                    .font(BoxFont.small)
                    .foregroundStyle(BoxColor.secondary)
                Spacer()
                if let elapsed {
                    Text("\(Int(elapsed)) s")
                        .font(BoxFont.mono)
                        .foregroundStyle(BoxColor.tertiary)
                }
            }
            if reduceMotion {
                Circle().fill(BoxColor.accent).frame(width: 4, height: 4)
            } else {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(BoxColor.accent)
                        .frame(width: geometry.size.width * (full ? 1 : progress), height: Theme.Box.progressHeight)
                }
                .frame(height: Theme.Box.progressHeight)
                .onAppear { withAnimation(.linear(duration: 1)) { progress = 1 } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
    }
}

/// Replace · Copy · Insert below · Send… · ⋯, the primary filled.
struct ActionRow: View {
    let model: BoxModel

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(model.actions, id: \.self) { action in
                if action == model.primaryAction {
                    PrimaryButton(title: action.title) { model.onAction(action) }
                        .accessibilityHint("Command Return")
                } else {
                    QuietButton(title: action.title) { model.onAction(action) }
                }
            }
            if model.offersOllama {
                QuietButton(title: "Ask Ollama") { model.askOllama() }
                    .accessibilityHint("The same question through the local vision model; slower, more detail")
            }
            Spacer(minLength: 0)
            Menu {
                if model.offersNewWindow {
                    Button(ResultAction.openInWindow.title) { model.onAction(.openInWindow) }
                }
                Button("Ask again") { model.resubmit() }
                Button("History…") { model.onOpenHistory() }
            } label: {
                Text("⋯")
                    .font(BoxFont.body)
                    .foregroundStyle(BoxColor.secondary)
                    .frame(width: Theme.Box.chipHeight, height: Theme.Box.chipHeight)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }
}

/// The toast line under the actions.
struct OutcomeLine: View {
    let outcome: ActionOutcome

    var body: some View {
        let text: String = switch outcome {
        case .done(let s): s
        case .failed(let s): s
        }
        Text(text)
            .font(BoxFont.small)
            .foregroundStyle(BoxColor.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One sentence in secondary colour plus up to two chips. No icon, no red.
struct FailureLine: View {
    let model: BoxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(model.failure?.message ?? "")
                .font(BoxFont.body)
                .foregroundStyle(BoxColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let chips = model.failureChips
            if !chips.isEmpty {
                HStack(spacing: Theme.Box.chipSpacing) {
                    ForEach(Array(chips.prefix(2).enumerated()), id: \.offset) { _, chip in
                        ChipButton(title: chip.title, action: chip.action)
                    }
                }
            }
        }
    }
}

/// The engine's one question and its options as chips.
struct AskingLine: View {
    let question: String
    let options: [String]
    var onOption: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(question)
                .font(BoxFont.body)
                .foregroundStyle(BoxColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            ChipFlow(spacing: Theme.Box.chipSpacing) {
                ForEach(options, id: \.self) { option in
                    ChipButton(title: option) { onOption(option) }
                }
            }
        }
    }
}

/// Chips wrap onto a second line rather than scroll off the card.
nonisolated struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 360 less the padding: the card's content width when nothing is proposed.
        let width = proposal.width ?? 336
        return CGSize(width: width, height: rows(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, y + rowHeight)
    }
}

/// Snapshots and previews draw the card opaque: the material has no
/// window behind it off screen.
nonisolated struct BoxOpaqueKey: EnvironmentKey {
    static let defaultValue = false
}

/// Snapshots decide the accent bar themselves: nil follows Reduce Motion,
/// true draws the bar, false the dot.
nonisolated struct BoxAnimatesKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var boxOpaque: Bool {
        get { self[BoxOpaqueKey.self] }
        set { self[BoxOpaqueKey.self] = newValue }
    }

    var boxAnimates: Bool? {
        get { self[BoxAnimatesKey.self] }
        set { self[BoxAnimatesKey.self] = newValue }
    }
}

#Preview("Empty") {
    BoxView(model: UIFixtures.model(.empty))
        .environment(\.boxOpaque, true)
        .padding(Theme.Space.xl)
}

#Preview("Done") {
    BoxView(model: UIFixtures.model(.done))
        .environment(\.boxOpaque, true)
        .padding(Theme.Space.xl)
}

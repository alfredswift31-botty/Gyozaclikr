import Foundation
import Testing
@testable import Gyozaclikr

struct ContractTests {
    @Test func chipsKeepTheirOrderAndShortcuts() {
        #expect(Chip.allCases.map(\.title) == ["Fix", "Shorter", "Formal", "Casual", "Summarise", "List", "Reply", "Remind"])
        #expect(Chip.allCases.map(\.shortcut) == Array(1...8))
    }

    @Test func outwardActionsNeedConfirmationAndLocalOnesDoNot() {
        #expect(ActionProposal.sendMail(to: ["a@b.c"], subject: "Hi", body: "…").needsConfirmation)
        #expect(ActionProposal.createReminder(title: "x", due: nil, dueText: nil).needsConfirmation)
        #expect(!ActionProposal.search(query: "x").needsConfirmation)
        #expect(!ActionProposal.openURL(URL(string: "https://example.com")!).needsConfirmation)
    }

    @Test func failuresReadAsSentences() {
        #expect(EngineFailure.tooLong(tokens: 6_100, limit: 2_600).message == "Selection is 6100 tokens; the on-device model takes 2600.")
        #expect(EngineFailure.refused.message.hasSuffix("."))
        #expect(EngineFailure.unavailable("Turn on Apple Intelligence.").message == "Turn on Apple Intelligence.")
    }

    @Test func anEmptySelectionHasNoContent() {
        #expect(!Selection.none.hasContent)
        #expect(Selection(kind: .text, text: "hello").hasContent)
    }
}

struct PromptTests {
    @Test func questionsMayLeaveTheSelection() {
        // 1.0.11: the old "say so instead of guessing" rule gagged every follow-up question.
        #expect(Prompts.instructions.contains("From general knowledge:"))
        #expect(Prompts.instructions.contains("use only the selected text and add nothing"))
        #expect(!Prompts.instructions.contains("instead of guessing"))
    }

    @Test func anEmptySelectionIsNotFenced() {
        #expect(Prompts.userPrompt("Make this formal", selection: nil) == "Make this formal")
        #expect(Prompts.userPrompt("Make this formal", selection: "  \n") == "Make this formal")
        let fenced = Prompts.userPrompt("Make this formal", selection: "hi there")
        #expect(fenced.hasPrefix("Make this formal\n\n"))
        #expect(fenced.hasSuffix("⟪hi there⟫"))
    }

    @MainActor
    @Test func requestsAboutTheSelectionAreRecognised() {
        #expect(Coordinator.refersToSelection("change this into formal writing"))
        #expect(Coordinator.refersToSelection("Summarise"))
        #expect(Coordinator.refersToSelection("make it shorter"))
        #expect(!Coordinator.refersToSelection("what is the capital of France"))
    }
}

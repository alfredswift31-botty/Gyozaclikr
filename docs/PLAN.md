# Gyozaclikr: plan

Status: researched and designed, not built. Three research reports in `docs/research/` back every claim here; the brief is `docs/BRIEF.md`; the box is specified in `docs/DESIGN.md`.

## 1. What the research settled

| Question | Answer | Source |
|---|---|---|
| Can Apple's on-device model take an image? | macOS 26: no, text only. **macOS 27: yes**, `Attachment(CGImage)` in prompts, with `label(_:)` so tools can reference it; system tools `OCRTool` and `BarcodeReaderTool`. Verified against Apple's documentation data. | research/apple-intelligence.md §1, §3 |
| Context window | 4,096 tokens per session for instructions, input and output together (Apple's 2026 table). One WWDC26 slide prints 8,192 for the 27.0 model. **Test on the Mac:** `SystemLanguageModel.default.contextSize`. | apple §1 |
| Is the model a source of facts? | No. GyozaYap on this Mac measured invented action items against explicit instructions. Apple's own guidance lists facts, maths and code as weak spots. | product §Engine facts |
| Tool calling | Works, but Apple says 3–5 tools at most, and 3B-class models get the *number* of calls wrong often. Route deterministically first; use tools only for compound requests; confirm anything outward. | apple §1, product §B |
| Programmatic Writing Tools | None. `NSWritingToolsCoordinator` is UI-driven. Cross-app rewriting is: read the selection, call Foundation Models, paste back. | apple §2 |
| Visual Look Up as data | Not available: identities are UI-only. Live Text OCR and Vision classification are data. | apple §3 |
| "Who is this person" | Not possible with Apple APIs; a vision model would guess. Refuse with a reason. | apple §5, product §Don't |
| "Where can I buy it" | Needs a web reverse-image search; the image leaves the Mac. Offer OCR of visible brand text plus a web search of that text, labelled. | same |
| Reading the selection | Accessibility API first (`AXSelectedText`, `AXBoundsForRange`), ⌘C simulation with pasteboard restore second, refuse under Secure Input. Needs the Accessibility grant. | system §1 |
| Region capture | `SCScreenshotManager` behind a rubber-band overlay. Needs Screen Recording, and macOS shows a monthly re-approval alert that one-shot screenshots do not escape. | system §3 |
| The box | Non-activating `NSPanel` hosting SwiftUI, anchored to the AX selection rectangle or the pointer, keyboard focus without stealing activation. | system §4 |
| Sending mail | `NSSharingService.composeEmail` by default (no permission; the user clicks Send). AppleScript to Mail for silent send needs the Automation grant and the apple-events entitlement. | apple §4, system §5 |
| Signing | Ad-hoc signing ties Accessibility and Screen Recording grants to one build; every update loses them. Use a self-signed code-signing certificate, held by CI as a secret, so the designated requirement is stable. | system §7 |
| Bigger Apple models | `PrivateCloudComputeLanguageModel` on macOS 27 needs a managed entitlement; ChatGPT has no third-party API. Out of scope. | apple §1 |

## 2. Architecture

```
Trigger ──► SelectionReader ──► Box (NSPanel + SwiftUI) ──► Router ──► Engine ──► Actions
hotkey      AX / ⌘C / region     quote · chips · input        chips      Apple FM    Replace
pill        Live Text OCR        streaming answer             pre-router Ollama      Copy / Insert
Services                         confirmation card            tools                  Mail / Reminder / Event / Note / Shortcut
```

- **App shell.** `LSUIElement` menu-bar agent, SwiftUI with AppKit where needed, Swift 5 mode with default MainActor isolation (as GyozaVitals), macOS 26 minimum, image features gated on macOS 27 at runtime.
- **Trigger.** Carbon `RegisterEventHotKey` (default ⌃Space, configurable); tap = text mode on the current selection, hold ≥ 300 ms = region capture. Services entry "Ask Gyozaclikr" always on. PopClip-style pill off by default (1.1).
- **SelectionReader.** AX read with bounds; ⌘C fallback with `changeCount` dance and pasteboard restore; Secure Input check. Returns `Selection { text?, image?, bounds?, sourceApp, isEditable }`.
- **Capture.** `ScreenCaptureKit` one-shot screenshot of a rubber-band rectangle; HiDPI aware; Live Text (`RecognizeTextRequest`) runs immediately for the OCR count and the text payload.
- **Box.** One pre-created non-activating panel; states per `docs/DESIGN.md`; opens in under 100 ms; `prewarm()` on summon.
- **Router.** Tier 1 chips: fixed prompts, context-filtered (a date surfaces Remind, a URL surfaces Open, an image surfaces Copy text). Tier 2: `NSDataDetector` and regex pre-router for addresses, dates, URLs and connector verbs; a single unambiguous connector executes without the model (the model only writes the body); compound or unresolved requests get a fresh session with at most four tools (`createReminder`, `createEvent`, `saveNote`, `sendMail`), whose dates and recipients the app re-parses. Factual image questions bypass the language model where a better engine exists (OCR, classification), and the Apple image path is used with a `@Generable` constrained answer.
- **Engine.** `AppleEngine` carried from GyozaYap (`AppleIntelligenceStatus`, the `GenerationError` mapping) plus `guardrails: .permissiveContentTransformations` for string transforms, `tokenCount(for:)` pre-checks, chunking for long selections, streaming. `OllamaEngine` for Qwen3-VL (`/api/chat` with base64 images, `keep_alive`, images downscaled to ≤ 1024 px), always labelled in the box. The engines share a `LanguageEngine` protocol.
- **Verification.** Extraction rows carry a `quote`; items whose quote is not in the selection are dropped and counted in the box. Dates come from `NSDataDetector`, never from the model.
- **Actions.** AX set first, ⌘V fallback with restore; Copy; Insert below; `NSSharingService` mail compose; EventKit reminders and events with write-only access; Notes via AppleScript (Automation grant) or the Notes share; `shortcuts run` for Shortcuts. Every outward action shows a confirmation card with every argument.
- **Diagnostics.** An Engines pane in Settings, in the GyozaVitals style: availability, `contextSize`, `variant`, whether an `Attachment` is accepted on this Mac (a 1-pixel probe at launch, result cached), Ollama reachability and the model list, every permission's state. Instrument first.

## 3. Scope

**v1.0 (build this).**
1. Hotkey trigger, Services entry, AX read with ⌘C fallback, Secure Input refusal.
2. The box: quote, chips, input, streaming, actions, error states, dark and light, Reduce Motion, VoiceOver basics.
3. Chips: Fix, Shorter, Formal, Casual, Summarise, List, Reply, Remind.
4. Free text to the Apple engine with the pre-router; connectors: Reminder, Event (EventKit, confirmed), Note, Open link, Search, Run Shortcut, Mail via `NSSharingService` compose.
5. Extraction with quote verification (dates, emails, amounts, action items, table to CSV).
6. Define the word under the pointer (Dictionary Services, no model).
7. Region capture with Live Text: copy the text out of an image, explain this error, table screenshot to CSV.
8. **Image questions on macOS 27** through `Attachment`, constrained to a short description plus OCR, with Vision classification as a cross-check; labelled "Apple Intelligence · on-device". Ollama Qwen3-VL as the labelled alternative, chosen explicitly or by `/local`.
9. Menu-bar item with Engines and Permissions status; history of the last 50 requests, local only.
10. Self-signed certificate signing in CI; `scripts/resign.sh` for local builds; `make reset-tcc`.

**v1.1.** Translate (locale-gated), units and currency without the model, commit message from a diff, PopClip-style pill, silent mail send via AppleScript behind the Automation grant, window summarise, link preview under the pointer, clipboard history (opt-in).

**Later.** Code explain and regex, form fill from a screenshot, hover definitions, message-screenshot reply, the larger Apple model if the entitlement ever opens.

**Never.** Face identification. Reverse image shopping. Fact checking by the 3B model. Maths in the model. Outward actions without confirmation. Continuous screen capture.

## 4. Milestones

| # | Milestone | Proof |
|---|---|---|
| 0 | Probe app: Engines pane only. Availability, `contextSize`, `variant`, an `Attachment` probe, Ollama check. | A screenshot from the owner's Mac answers the three open questions before any UI is built. |
| 1 | Capture and box: hotkey, AX read, the panel with quote and input, Replace and Copy. No model. | Select text in TextEdit, Safari, Mail, Terminal and a Chromium app; the box appears under the selection; Replace works where the field is editable. |
| 2 | Apple engine: chips and free text, streaming, error states, long-selection chunking. | The eight chips on five kinds of text; guardrail and overflow states rendered. |
| 3 | Connectors and confirmation: pre-router, four tools, EventKit, mail compose, Shortcuts. | Eight transcripts from `docs/research/product-and-ux.md` §B reproduced, including the compound and the ambiguous one. |
| 4 | Region capture, Live Text, image questions on 27, Ollama path. | A screenshot of a table becomes CSV; a photo of a plant gets a description; the Ollama state is labelled. |
| 5 | Signing, CI, snapshots, devlog, 1.0 release. | Grants survive an update. |

CI as in GyozaVitals: macOS 26 runner, unit tests, snapshot renders of every box state printed to the log, a verify step for the entitlements and the signature.

## 5. Permissions
Accessibility (first text trigger), Screen Recording (first region capture; monthly re-approval expected), Reminders and Calendars write-only (first use), Automation to Notes and optionally Mail (first use), Contacts (only for "mail to <name>"). None for Apple Intelligence beyond it being on. The Engines pane shows every grant's state and a Grant… button.

## 6. Risks, in order
1. **The 3B model's answers about images** may be too weak to be worth showing. Mitigation: milestone 0 measures it on the owner's pictures; Ollama stays as the alternative; the constrained `@Generable` answer limits damage.
2. **Image input gated by hardware tier** (press reports an M3-and-12 GB tier for the most advanced model; the owner has an M4 with 16 GB). Milestone 0 settles it.
3. **Accessibility coverage**: Electron, Firefox and some web views do not expose selections; the ⌘C fallback covers most, Secure Input blocks the rest. The Services entry is the universal fallback.
4. **Screen Recording re-approval** mid-capture. Handle the error as "re-approval pending", retry once, explain in the box.
5. **Tool-calling misroutes.** The pre-router and the confirmation card contain it; a second outward call per request is refused.
6. **Memory on 16 GB**: the Apple model plus Ollama's 6 GB plus a generation in Qwen Image will swap. GyozaVitals shows it; Gyozaclikr unloads nothing and says when Ollama is busy.

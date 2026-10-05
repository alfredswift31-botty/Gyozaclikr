# Gyozaclikr: what Apple actually exposes to a third-party Mac app (as of 2026-10-05)

Scope: macOS 26 ("Tahoe") and macOS 27 APIs, Apple-silicon Mac with 16 GB, Swift/SwiftUI/AppKit, no server. Every claim carries a source number; `[test]` marks something I could not verify and gives the experiment that settles it.

## 0. Headline findings

| Question | Answer |
|---|---|
| Can the on-device model take images? | **Yes on macOS 27** (`Attachment(CGImage)`), **no on macOS 26** (text only). [S4][S5][S6] |
| Context window | **4,096 tokens** per session, shared by input and output [S2][S9]. A WWDC26 slide prints `contextSize // 8192` for the 27.0 model [S3]; Apple's own June-2026 table still says 4K [S9]. `[test]` `print(SystemLanguageModel.default.contextSize)` on macOS 27. |
| Programmatic Writing Tools (rewrite a string, no UI)? | **No.** The coordinator is UI-driven; `showWritingTools(_:)` only opens the panel. Use Foundation Models with `permissiveContentTransformations`. [S20][S21][S22][S13] |
| Bigger Apple model from third-party code? | **Yes, macOS 27:** `PrivateCloudComputeLanguageModel` (32K context, reasoning), but it needs a managed entitlement (Small Business Program + <2M downloads) and has a per-user daily quota. **ChatGPT: no API** (only the Shortcuts "Use Model" action or your own key). [S10][S11][S12][S27] |
| "Who is this person?" | Nothing Apple ships will do it; Visual Look Up does not identify people; guardrails + no reverse search. Needs a web service, with the privacy cost that implies. [S29][S31] |
| Background rate limiting | `rateLimited` "will only happen if your app is running in the background and exceeds the system defined rate limit" [S8]. A menu-bar/accessory app is an edge case. `[test]` below. |

## 1. Foundation Models framework

**Model.** The on-device model is ~3B parameters, 2-bit quantization-aware trained, with KV-cache sharing; Apple's 2025 tech report also describes a vision encoder for the on-device model [S1]. Apple ships three model versions keyed to OS: 26.0–26.3, 26.4, 27.0 [S4]. 26.4 "improves instruction-following and tool-calling abilities" and reduced guardrail false positives [S9]; 27.0 is "rebuilt... more intelligent; better at logic and tool calling" [S3], and Apple says the new Apple Foundation Models were built "working together with Google and leveraging the technologies behind their Gemini family" [S7]. Expect prompt behavior to shift across versions; Apple tells you to version prompts by `#available` [S36].

**Input modalities.** macOS 26: text only. macOS 27: `Attachment` (iOS/macOS 27.0+) adds images to prompts and instructions; accepted types are CGImage, CIImage, CVPixelBuffer and file URLs (plus NSImage/UIImage per the session); "the framework performs the necessary scaling and color conversions"; "larger images will consume more tokens and incur more latency"; no documented cap on count or pixels [S3][S5][S6]. Attachments can be `.label("x")`-ed so tools can reference them via `ImageReference` [S5][S6]. Guardrails check images as well as text [S13].

```swift
let session = LanguageModelSession(instructions: "Answer in one short paragraph.")
let r = try await session.respond {
    "What is this? If it is a product, name the brand and model."
    Attachment(cgImage)            // macOS 27+
}
```

**Context window and overflow.** 4,096 tokens per `LanguageModelSession`, roughly 3–4 Latin characters per token, ~1 token per CJK character; instructions, prompts, tool schemas, tool I/O, `@Generable` schemas and all responses count [S2]. Overflow throws `exceededContextWindowSize` (26) / `LanguageModelError.contextSizeExceeded` (27) and "the session won't be able to respond"; recovery is a new session seeded with a condensed `Transcript` [S2][S14]. `contextSize` and `tokenCount(for:)` exist since 26.4 [S4][S9]. `maximumResponseTokens` can truncate mid-sentence; prefer "in 3 sentences" prompting [S2]. Keep at most 3–5 tools per session [S2].

**Streaming, guided generation.** `session.streamResponse(to:)` yields partial snapshots (WWDC25); `@Generable` / `@Guide` types are constrained-decoded ("strong guarantees that the model generates instances of your type"), with `GenerationSchema`/`DynamicGenerationSchema` for runtime schemas [S4a]. For classification use `GenerationOptions(samplingMode: .greedy)` [S5]. In guided mode a refusal surfaces as `LanguageModelError.refusal` with an async `explanation` [S13].

**Tool calling.** `Tool` = `name`, `description`, `Arguments: Generable`, `call(arguments:)`; definitions are injected into the prompt and the model "decide[s] when and how often to call the tool"; tools run concurrently, back-to-back chaining is supported [S15]. macOS 27 adds `GenerationOptions.ToolCallingMode` (`.allowed`, `.disallowed`, `.required`), `DynamicProfile` (swap instructions/tools/model per turn), `usage` token accounting, and system tools: `OCRTool`, `BarcodeReaderTool` (Vision) and `SpotlightSearchTool` (Core Spotlight) [S9][S16][S17][S18]. Reliability: Apple publishes no accuracy numbers; a 3B model is not a dependable free-form router. For "send this to x@gmail.com in formal style", do **two deterministic steps**: (1) `respond(generating: Intent.self, options: .greedy)` with a small `@Generable enum { case rewrite(Style), case email(to: String, style: Style), case explain, ... }`; (2) execute the action in code. Reserve `Tool` for information-gathering (contacts lookup). Measure with the new Evaluations framework [S3][S9].

**Sessions / instructions.** `LanguageModelSession(model:tools:instructions:)`; "A session obeys instructions over a prompt", so never put user text in instructions (prompt injection) [S13]. `prewarm()` reduces first-token latency [S2]. For non-US locales add the exact phrase `"The person's locale is <id>."` and "You MUST respond in X" [S19].

**Availability.** `SystemLanguageModel.default.availability`: `.available`, `.unavailable(.deviceNotEligible)`, `.unavailable(.appleIntelligenceNotEnabled)`, `.unavailable(.modelNotReady)` (downloading/other) [S4][S4b]. Unsupported language is detected per call: `unsupportedLanguageOrLocale` [S19]; pre-check with `supportsLocale()`/`supportedLanguages`. Hardware: Apple Intelligence needs M1 or later and ~7 GB storage [S37]. **Caveat for macOS 27:** press coverage of Apple's compatibility footnotes says the "most advanced on-device" Apple Intelligence model (Siri AI expressive voices, enhanced dictation; up to 14 GB storage) requires **M3 or later with ≥12 GB**, while M1/M2 Macs keep the base tier [S38][S39]. Whether the Foundation Models 27.0 model and its image input are part of the gated tier is **not documented**. `[test]` on the target Mac: print `SystemLanguageModel.default.variant`, call `respond` with an `Attachment`, and watch for `LanguageModelError.unsupportedCapability` ("the model being used doesn't support a particular feature") [S14].

**Rate limits.** On-device `SystemLanguageModel` is listed as "Unlimited" usage [S11]; `rateLimited` is documented as background-only [S8]; `concurrentRequests` fires if you call `respond` twice on one session [S14]. `[test]` run Gyozaclikr as `LSUIElement` (no Dock icon, floating panel) and fire 30 requests in a loop; log whether `LanguageModelError.rateLimited` appears, and whether `NSApp.activate` before the call changes it.

**Guardrails and failure modes.** Two layers: the model "trained to handle sensitive topics with care" and guardrails that "aim to block harmful or sensitive content, such as self-harm, violence, and adult materials"; both input and output are checked; violation throws `guardrailViolation` [S13]. Medical/legal are not named categories; the documented risk is refusal text ("Sorry, I can't help with that") that you "might not be able to programmatically determine" from a normal answer [S13]. Known false positives: news-article summarization was widely rejected in 26.0 [S40]; Apple improved this in 26.4 and 27 [S3][S9]. For rewrite/summarize of arbitrary selected text use `SystemLanguageModel(guardrails: .permissiveContentTransformations)`: skips guardrails for **string** output only (guided generation keeps them), model-level refusals can still occur [S13]. Guardrails only cover supported languages; mixed-language snippets can slip past or fail oddly [S19]. PCC guardrails are stricter and not configurable [S13].

**Languages.** The model is "multilingual... any language that Apple Intelligence supports" [S19]. Apple's list (support page, blocked from this sandbox) per press: English (several regions), French, German, Italian, Portuguese (BR and PT), Spanish, Chinese (Simplified, Traditional), Japanese, Korean, Danish, Dutch, Norwegian, Swedish, Turkish, Vietnamese [S41]. Treat `supportedLanguages` as the truth at runtime.

**Larger model / ChatGPT.** macOS 27 `PrivateCloudComputeLanguageModel`: 32,768-token context, reasoning levels `.light/.moderate/.deep` via `ContextOptions`, usage accounting, no API keys, "no token costs to you"; needs network; per-user **daily quota** (`quotaUsage`, `quotaLimitReached`, `limitIncreaseSuggestion.show()` upsells iCloud+) [S10][S11][S12]. Entitlement: App Store Small Business Program + <2M first-time downloads + managed entitlement request; TestFlight/ad-hoc installs allowed [S27]. A Developer-ID-only app without the entitlement cannot use it `[test]`. Image input on PCC is "not mentioned" in the session [S12] `[test]`. ChatGPT: no third-party API; reachable only through Shortcuts "Use Model → ChatGPT" [S42] or by bringing your own key via the `LanguageModel` protocol (Anthropic and Google publish Swift packages) [S3][S28]. macOS 27 also ships the `fm` CLI (`fm respond --image ... --model pcc`) and a Python SDK [S25].

**What changed in macOS 27 (summary).** Image input; PCC model; `LanguageModel` protocol with `CoreAILanguageModel` and `MLXLanguageModel`; `DynamicProfile`; `ToolCallingMode`; system tools (OCR, barcode, Spotlight); restructured errors (`LanguageModelError`); Evaluations framework; `fm` CLI; open-source "foundation-models-utilities" with rolling-window history and a `ChatCompletionsLanguageModel` that talks to any OpenAI-style server, i.e. **Ollama's `/v1/chat/completions` can back a `LanguageModelSession`** [S9][S26]. Adapters: a `SystemLanguageModel(adapter:)` path with Apple's adapter-training toolkit has existed since 26.0, but adapters must be retrained per base-model version; I found no 27-specific adapter change and do not recommend it for this app `[test: check Adapter docs in the 27 SDK]`.

## 2. Writing Tools

- Free: `NSTextView`, `NSTextField`, SwiftUI `TextField`/`TextEditor` "already include the required support" [S20]; `WKWebView` via `WKWebViewConfiguration.writingToolsBehavior` (macOS 15+) [S23]; level controlled by `NSWritingToolsBehavior` `.none/.default/.complete/.limited` [S24].
- Custom views: `NSWritingToolsCoordinator` (macOS 15.2+) with a delegate that hands text to the system and applies replacements; "When a coordinator is present on a view, the system adds UI elements to initiate Writing Tools operations" [S20]. There is no method to start a specific tool; the only invocation API is the `NSResponder.showWritingTools(_:)` IBAction, which shows the panel [S21].
- Confirmed: no public API rewrites/proofreads/summarizes a string headlessly. Consequence: "rewrite the selection in app X" = read the selection (Accessibility `AXSelectedText`, or simulate ⌘C; both need the Accessibility permission), run Foundation Models with `permissiveContentTransformations`, then paste/`AXReplace` back. Shortcuts has no Writing Tools action I could find, so there is no automation back door either.

## 3. Images: every public path to "what is this picture"

| Path | macOS | Input | What you get back | Notes |
|---|---|---|---|---|
| VisionKit `ImageAnalyzer` + `ImageAnalysis` | 13+ | `CGImage`, `NSImage`, `CIImage`, `CVPixelBuffer`, URL [S29] | `transcript` (OCR text), `hasResults(for: .text/.machineReadableCode/.visualLookUp)` [S30] | Works on any screen-captured `CGImage`. Visual Look Up **results are UI-only**: `.visualLookUp` "presents a button for more information" in `ImageAnalysisOverlayView`; no API returns the identified species/landmark [S31][S32]. |
| `ImageAnalysisOverlayView` subject lift | 13+ | same | `subjects`, `subject(at:)`, `image(for:)` (background removed) [S32] | Data is available for subjects, not their identity. |
| Visual Look Up categories (system feature) | 12+ | — | plants/flowers, animals, insects, birds, pets, landmarks, sculptures/art, books, album covers, dishes, laundry symbols, dashboard lights [S33] | Only via Photos/Quick Look/overlay UI. |
| Vision `RecognizeTextRequest` | 15+ (Swift API) | `CGImage` etc. | `RecognizedTextObservation` with boxes; `recognitionLevel`, `automaticallyDetectsLanguage`, `customWords` [S34] | Best OCR path; use for screenshots. |
| Vision `ClassifyImageRequest` | 15+ | same | whole taxonomy of generic labels ("bicycle") with confidence; filter with `hasMinimumPrecision/Recall` [S35][S35a] | Category, never identity. |
| Vision `DetectBarcodesRequest`, `DetectDocumentSegmentationRequest`, `GenerateForegroundInstanceMaskRequest` | 15+ | same | barcodes; document quad + mask; instance masks [S43][S44][S45] | |
| Foundation Models + `Attachment` | **27+** | `CGImage` etc. | free text or `@Generable` enum/struct; add `OCRTool`/`BarcodeReaderTool`/custom Vision tool [S5][S16] | The real "what is this" on-device path. Quality: 3B model; good for description/classification, weak for brand/model/person. |
| Visual Intelligence framework | **27+ on Mac** [S46] | system screenshot selection → your `IntentValueQuery` | `SemanticContentDescriptor.labels` (generic en_US words like "tower") + `pixelBuffer` [S47] | **Inbound only**: your app can be a search provider; it cannot invoke visual intelligence or read its answer. |
| Shortcuts "Use Model" | 26+ | text, variables; images: on-device model refused them in 26, PCC accepted but was slow with full-size images (press) [S42] | text/structured output; run from code with `Process` → `shortcuts run "Name" --input-path img.png --output-path out.txt` [S48] | Clunky: Shortcuts launch + model; permission dialogs; no streaming. `[test]` whether the 27 on-device "Use Model" accepts images. |
| Image Playground `ImageCreator` | 15.4–26 | text/image concepts | generated images | Deprecated and non-functional in 27; only `imagePlaygroundSheet`/`ImagePlaygroundViewController` UI remains [S49][S50]. |

**Honest conclusion for "what is this / who is this / where can I buy it":**

- *What is this (object, animal, plant, screenshot of a UI, chart):* on-device, macOS 27: Foundation Models with an image attachment, constrained to a `@Generable` answer plus `OCRTool`, with Vision `ClassifyImageRequest` as a cheap cross-check. On macOS 26: OCR + classification only; a vision LLM needs Ollama.
- *Who is this:* **not possible with Apple APIs** (no face identification API beyond Photos' private People model; guardrails; VLMs hallucinate names). Do not promise it.
- *Where can I buy it:* needs a web reverse-image search (Google Lens/Bing Visual Search/TinEye) or a product-recognition API; the image leaves the Mac and is tied to an API key or account. On-device you can only produce a text query ("blue Patagonia fleece") and open a browser search.

**Ollama fallback (Qwen3-VL 8B).** Request shape [S51]:

```json
POST http://127.0.0.1:11434/api/chat
{
  "model": "huihui_ai/qwen3-vl-abliterated:8b-instruct",
  "stream": true,
  "keep_alive": "10m",
  "options": { "num_predict": 200, "temperature": 0.2 },
  "messages": [
    { "role": "system", "content": "Answer in at most 3 sentences." },
    { "role": "user", "content": "What is this?", "images": ["<base64 PNG/JPEG, no data: prefix>"] }
  ]
}
```

Response chunks carry `message.content`; the final chunk has `done:true` plus `load_duration`, `prompt_eval_count/duration`, `eval_count/duration` (nanoseconds) [S51]. Latency on a 16 GB M-series at 8B Q4 (~5–6 GB weights): llama.cpp 7B-Q4 reference numbers are M1 108 PP / 14 TG tok/s, M2 180 / 22, M1 Pro 266 / 36, M2 Pro 341 / 39, M3 187 / 21, M4 221 / 24 [S52]; one community run of Qwen3-VL-8B-Instruct on an M1 Pro 16 GB reports ~158 PP / 32 TG at 1k context (MLX) [S53]. A screenshot encodes to several hundred to ~1.5k visual tokens, so expect: cold load 2–5 s, prefill 2–8 s, 100-token answer 3–7 s, i.e. roughly 5–15 s cold / 3–10 s warm on M1–M2 class, about half on M-Pro/M4. Downscale to ≤1024 px on the long side, cap `num_predict`, keep the model resident with `keep_alive`. Memory: Ollama's 6 GB plus the Apple model and the rest of macOS is fine at 16 GB but leaves no room for a second model.

## 4. Other Apple engines

| Engine | Availability / shape | Limits for Gyozaclikr |
|---|---|---|
| **Translation** | macOS 15+: `TranslationSession` obtained only through SwiftUI `.translationTask(configuration)`; `translate(_:)`, batch `translations(from:)`/`translate(batch:)`; `LanguageAvailability().status(from:to:)` → `.installed/.supported/.unsupported`; language packs download with a system permission sheet; `prepareTranslation()` [S54][S55]. ~20 languages on-device (Arabic, Chinese S/T, Dutch, English, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Polish, Portuguese, Russian, Spanish, Thai, Turkish, Ukrainian, Vietnamese) [S56]. | Needs a (possibly hidden) SwiftUI host view to get a session; same-language pairs unsupported. |
| **Speech** | macOS 26+: `SpeechAnalyzer` + `SpeechTranscriber(locale:preset:)`, on-device, `AssetInventory` downloads models, `AsyncSequence` of volatile→final results, `supportedLocales`/`installedLocales` [S57][S58]. | Microphone permission; "The analyzer can only analyze one input sequence at a time". Good for dictating the request. |
| **NaturalLanguage** | `NLLanguageRecognizer.dominantLanguage(for:)`, `languageHypotheses`, `languageConstraints`; "accuracy is lower" for a few words [S59]. | Use before calling the model to avoid `unsupportedLanguageOrLocale`. |
| **Spotlight** | 27+: `SpotlightSearchTool` searches **your app's** Core Spotlight index and files your app created, default `complete` mode "works best with PCC" [S18]. System-wide search is still `NSMetadataQuery`/`mdfind`. | Not a system-wide RAG. |
| **EventKit** | macOS 14+: `requestWriteOnlyAccessToEvents()` / `requestFullAccessToEvents()` / `requestFullAccessToReminders()` with `NSCalendarsWriteOnlyAccessUsageDescription`, `NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`; the old `requestAccess(to:)` throws on new systems [S60]. | One TCC prompt each. |
| **Contacts** | `CNContactStore.requestAccess(for: .contacts)` + `NSContactsUsageDescription` [S61]. | Needed to resolve "send to Bob". |
| **Mail** | (a) `NSSharingService(named: .composeEmail)` with `recipients`/`subject` and `perform(withItems:)` opens the default mail client's compose window, no permission, sandbox-safe, user must click Send [S62]. (b) `NSAppleScript`/Scripting Bridge driving Mail.app can create **and send** silently; requires `NSAppleEventsUsageDescription` (prompt: "X wants to control Mail") [S63]; hardened-runtime apps need the `com.apple.security.automation.apple-events` entitlement; sandboxed apps additionally need scripting-target/temporary-exception entitlements [S64]. (c) `mailto:` via `NSWorkspace.shared.open` opens compose only. | A non-sandboxed Developer-ID app can use all three; the Automation TCC prompt appears once per target app. For "send this to x@gmail.com", (a) is the honest default, (b) only with an explicit "send without review" setting. |

## 5. What the idea cannot do with Apple Intelligence alone (and the substitute)

1. **Image understanding on macOS 26** — text-only model. Substitute: Ollama Qwen3-VL (section 3), or require macOS 27.
2. **Identify a person, or a specific product/brand/price** — no Apple API; Visual Look Up results are UI-only; 3B model hallucinates names. Substitute: web reverse-image search with explicit consent; otherwise answer with a description plus a search link.
3. **Headless Writing Tools** — none. Substitute: Foundation Models + `permissiveContentTransformations`; read/write the other app's selection through Accessibility.
4. **Long inputs** — 4K tokens shared with the answer. Substitute: chunk + merge (TN3193), or PCC (32K) if you get the entitlement, or Ollama (Qwen3-VL supports very long contexts) [S2][S11].
5. **Reasoning-grade answers ("explain this legal clause")** — on-device has no reasoning mode; PCC does but is quota-limited and entitlement-gated. Substitute: hermes3:8b via Ollama, or BYO cloud key through the `LanguageModel` protocol.
6. **Reliable free-form command routing** — small model, no published tool-accuracy. Substitute: `@Generable` intent enum with greedy sampling, then code.
7. **Any use when Apple Intelligence is off, the device is ineligible, the model is downloading, or the language is unsupported** — `availability` tells you which; the substitute is the Ollama path, surfaced honestly in the UI.
8. **Sending mail silently** — not an Apple Intelligence feature at all; needs Mail.app automation and a TCC grant, or a compose window the user confirms.
9. **Image generation** — `ImageCreator` is dead in 27; only the system Image Playground sheet.
10. **Guardrail-free handling of sensitive selections** — permissive mode removes the guardrail but not model refusals; and guided generation always keeps guardrails. Substitute: detect refusal text and fall back to Ollama.
11. **Background/agent-style batch processing** — background requests are the one documented rate-limit case. Keep requests user-initiated.

## Sources

- [S1] Apple Foundation Models Tech Report 2025 (arXiv mirror): https://arxiv.org/abs/2507.13575
- [S2] TN3193 Managing the on-device foundation model's context window: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- [S3] WWDC26 241 What's new in the Foundation Models framework: https://developer.apple.com/videos/play/wwdc2026/241/
- [S4] SystemLanguageModel: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
- [S4a] Foundation Models framework overview: https://developer.apple.com/documentation/foundationmodels
- [S4b] UnavailableReason: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason
- [S5] Analyzing images with multimodal prompting: https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting
- [S6] Attachment: https://developer.apple.com/documentation/foundationmodels/attachment
- [S7] WWDC26 Platforms State of the Union recap: https://developer.apple.com/videos/play/wwdc2026/122/
- [S8] GenerationError.rateLimited: https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:)
- [S9] Foundation Models updates: https://developer.apple.com/documentation/updates/foundationmodels
- [S10] PrivateCloudComputeLanguageModel: https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel
- [S11] Adding server-side intelligence with Private Cloud Compute: https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute
- [S12] WWDC26 319 Build with Apple Foundation Model on Private Cloud Compute: https://developer.apple.com/videos/play/wwdc2026/319/
- [S13] Improving the safety of generative model output: https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output
- [S14] LanguageModelError (27): https://developer.apple.com/documentation/foundationmodels/languagemodelerror ; GenerationError (26): https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror
- [S15] Tool protocol: https://developer.apple.com/documentation/foundationmodels/tool
- [S16] OCRTool: https://developer.apple.com/documentation/vision/ocrtool
- [S17] WWDC26 242 Build agentic app experiences: https://developer.apple.com/videos/play/wwdc2026/242/
- [S18] SpotlightSearchTool: https://developer.apple.com/documentation/corespotlight/spotlightsearchtool
- [S19] Supporting languages and locales: https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models
- [S20] NSWritingToolsCoordinator: https://developer.apple.com/documentation/appkit/nswritingtoolscoordinator
- [S21] NSResponder.showWritingTools(_:): https://developer.apple.com/documentation/appkit/nsresponder/showwritingtools(_:)
- [S22] Guardrails: https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/guardrails
- [S23] WKWebViewConfiguration.writingToolsBehavior: https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/writingtoolsbehavior
- [S24] NSWritingToolsBehavior: https://developer.apple.com/documentation/appkit/nswritingtoolsbehavior
- [S25] WWDC26 334 fm CLI and Python SDK: https://developer.apple.com/videos/play/wwdc2026/334/
- [S26] foundation-models-utilities (ChatCompletionsLanguageModel, history modifiers): https://github.com/apple/foundation-models-utilities
- [S27] Accessing Private Cloud Compute (eligibility): https://developer.apple.com/private-cloud-compute/
- [S28] LanguageModel protocol: https://developer.apple.com/documentation/foundationmodels/languagemodel
- [S29] VisionKit ImageAnalyzer: https://developer.apple.com/documentation/visionkit/imageanalyzer
- [S30] ImageAnalysis: https://developer.apple.com/documentation/visionkit/imageanalysis
- [S31] ImageAnalysisOverlayView.InteractionTypes: https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview/interactiontypes
- [S32] ImageAnalysisOverlayView: https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview
- [S33] Visual Look Up categories (Macworld): https://www.macworld.com/article/2424053/how-to-use-plants-birds-and-other-object-identifiers-in-photos.html
- [S34] RecognizeTextRequest: https://developer.apple.com/documentation/vision/recognizetextrequest
- [S35] ClassifyImageRequest: https://developer.apple.com/documentation/vision/classifyimagerequest ; [S35a] Classifying images for categorization and search: https://developer.apple.com/documentation/vision/classifying-images-for-categorization-and-search
- [S36] Updating prompts for new model versions: https://developer.apple.com/documentation/foundationmodels/updating-prompts-for-new-model-versions
- [S37] Apple Intelligence hardware requirements (AppleInsider): https://appleinsider.com/articles/24/06/10/apple-intelligence---what-macs-ipads-and-iphones-are-required
- [S38] TechSpot, "iOS 27: most advanced on-device AI needs 12GB" (search snippet only; site blocked here): https://techspot.com/news/112702-ios-27-most-advanced-device-ai-needs-12gb.html
- [S39] MacRumors, Apple Intelligence up to 30 GB on macOS 27 Macs (snippet only): https://macrumors.com/2026/09/23/apple-intelligence-30gb-some-macs-macos-27
- [S40] Developer Forums, "Model Guardrails Too Restrictive?": https://developer.apple.com/forums/thread/787736
- [S41] Apple Intelligence languages (Thurrott): https://www.thurrott.com/a-i/309670/apple-intelligence-to-add-support-for-german-italian-portuguese-korean-and-other-languages-in-2025 ; Apple's own list: https://support.apple.com/en-us/121115
- [S42] Six Colors, Use Model action (on-device model and images): https://sixcolors.com/post/2025/06/experimenting-with-apples-ai-models-inside-shortcuts/ ; MacStories: https://www.macstories.net/notes/i-have-many-questions-about-apples-updated-foundation-models-and-the-great-use-model-action-in-shortcuts/
- [S43] DetectBarcodesRequest: https://developer.apple.com/documentation/vision/detectbarcodesrequest
- [S44] DetectDocumentSegmentationRequest: https://developer.apple.com/documentation/vision/detectdocumentsegmentationrequest
- [S45] GenerateForegroundInstanceMaskRequest: https://developer.apple.com/documentation/vision/generateforegroundinstancemaskrequest
- [S46] Visual Intelligence framework (macOS 27.0+): https://developer.apple.com/documentation/visualintelligence ; Apple developer page "onscreen content on Mac": https://developer.apple.com/apple-intelligence/
- [S47] Integrating your app with visual intelligence: https://developer.apple.com/documentation/visualintelligence/integrating-your-app-with-visual-intelligence
- [S48] `shortcuts run` CLI (Apple user guide; mirror explanation): https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac ; https://flaviocopes.com/courses/automate-macos/run-shortcuts-from-terminal/
- [S49] ImageCreator (availability 15.4–27.0): https://developer.apple.com/documentation/imageplayground/imagecreator
- [S50] ImageCreator deprecation write-up: https://blakecrosley.com/blog/imagecreator-deprecated-ios-27
- [S51] Ollama API reference (/api/chat, images as base64 array): https://github.com/ollama/ollama/blob/main/docs/api.md
- [S52] llama.cpp Apple-silicon benchmark table (7B Q4_0): https://github.com/ggml-org/llama.cpp/discussions/4167
- [S53] Community Qwen3-VL-8B M1 Pro 16 GB benchmark (snippet only; site blocked here): https://omlx.ai/benchmarks/lm2xjyyg
- [S54] Translation framework: https://developer.apple.com/documentation/translation
- [S55] Translating text within your app: https://developer.apple.com/documentation/translation/translating-text-within-your-app
- [S56] Translation language list (Kodeco/AppleInsider via search): https://appleinsider.com/inside/translate
- [S57] SpeechAnalyzer: https://developer.apple.com/documentation/speech/speechanalyzer
- [S58] SpeechTranscriber: https://developer.apple.com/documentation/speech/speechtranscriber
- [S59] NLLanguageRecognizer: https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer
- [S60] Accessing Calendar using EventKit (access levels, keys): https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui
- [S61] NSContactsUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription
- [S62] NSSharingService.Name.composeEmail: https://developer.apple.com/documentation/appkit/nssharingservice/name/composeemail
- [S63] NSAppleEventsUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription
- [S64] Apple Events entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events
- [S65] MLX Swift LM (MLXLanguageModel bridge, requires 27 SDK): https://github.com/ml-explore/mlx-swift-lm

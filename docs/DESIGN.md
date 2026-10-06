# Gyozaclikr: design contract

The box is the product. It appears beside what the user selected, takes one line of intent, and shows the answer and the actions. It follows the suite's language (Swiss, typographic, one accent, hairlines, mono figures, the 8-pt grid) and is allowed exactly two playful moments, named below. The full reasoning and the references compared (ChromeOS Select to Search and Quick Insert, Windows Click to Do, macOS Writing Tools and Visual Intelligence, Circle to Search, PopClip, Raycast, Arc Max, Notion AI, Figma and Linear palettes) are in `docs/research/product-and-ux.md` §C.

## Form
A card, not a pill. 360 pt wide on the 8-pt grid; height follows content; widens to 480 pt in one step when an answer streams. Radius 10 pt. 1-pt hairline in `separatorColor`. System window material; the panel's own shadow and nothing else. One accent for the live state: the user's system accent. System font 13 pt; SF Mono 11 pt for counts and timings; labels in secondary colour.

## Anchor
Text: 8 pt below the bottom-left of the selection's last line, from the Accessibility bounds when available, else the pointer. Region: the region's bottom-left. Word under pointer: 12 pt below-right of the pointer. Flips above when there is no room below; shifts to stay 16 pt inside the screen; never covers the selection. Non-activating panel, so the source app keeps focus and Replace still works.

## States
1. **Summoned.** Appears at full opacity within 100 ms; a 120 ms fade, no scale. The model prewarms here.
2. **Empty.** Placeholder "Ask about this selection…" (or "…this image", "Define *word*…"), the content preview, the chip row with the first chip pre-suggested (dim accent outline; Tab accepts it).
3. **Typing.** Chips filter by prefix. Enter sends; ⇧Enter newline; ↑ recalls the last request; Esc closes.
4. **Streaming.** The chip row collapses to one line, "Apple Intelligence · on-device", in secondary colour. The answer streams below with light Markdown: bold, lists, inline and fenced code in mono with a hairline box; no headings; tables offered as CSV via Copy, not drawn. Text appears per snapshot with a 40 ms coalescing window.
5. **Done.** Action row: **Replace · Copy · Insert below · Send… · ⋯**. Replace is primary when the source was editable; Copy otherwise. "Open in new window" appears past about 12 lines.
6. **Error, refused, unavailable.** Same card; one sentence in secondary colour and up to two chips. No icon, no red. The availability messages are GyozaYap's four.
7. **Confirmation.** For mail, reminders, events and shortcuts: a card listing every argument (To, Subject, two body lines; title and the date in words, "Fri 10 Oct, 09:00"), with Edit and the action. Never for local transforms; undo is their safety net.

## The selection in the box
Text: a two-line quote in secondary colour with a 1-pt left rule, ellipsis, token count in mono at the right ("412 tok"). Image: a 48-pt-tall thumbnail with a hairline, aspect preserved, and the OCR word count once Live Text finishes ("OCR · 83 words"). Word under pointer: only in the placeholder.

## Keys
Enter sends · ⇧Enter newline · Esc closes (a second Esc first cancels a running generation) · ↑ recalls · ⌘1–⌘8 chips · Tab accepts the suggested chip · ⌘↩ primary action · ⌘C copies the answer · `/local` forces Ollama · `/history` opens history.

## The thinking indicator
One word in secondary colour, specific to the task: "Reading…", "Rewriting…", "Extracting…". A 2-pt accent bar under it fills over the first-token budget and stays full while streaming. No spinner. The one animation allowed elsewhere: the menu-bar gyoza nudges once when a result lands.

## Budgets
Box visible < 100 ms (pre-created panel; the selection is read first, because a box that takes keyboard focus would read itself). OCR < 400 ms. First token < 1 s on-device with prewarm; past 2.5 s the status reads "Model is warming up…". Ollama: 10–40 s, elapsed seconds in mono.

## Engines, visibly
Apple's model is the default and is named in the collapsed row. The Ollama state is labelled "Ollama · Qwen3-VL-8B · on this Mac" and carries a 2-pt blue-to-violet gradient hairline along the box's top edge: the gradient means "the other engine". A non-localhost Ollama host adds "leaves this Mac" and a one-time confirmation.

## Dark, light, accessibility
Semantic colours only. Increase Contrast: 1.5-pt hairlines, solid chip outlines. Reduce Transparency: opaque window background. Reduce Motion: no fade or resize animation; the accent bar becomes a static dot. VoiceOver: the panel announces "Gyozaclikr, selection of 412 tokens"; chips are buttons with their shortcut as the hint; the answer is a polite live region per sentence; confirmation cards read every argument.

## Menu bar
A monochrome template gyoza. Menu: Open box (shortcut shown), Last answer, History…, Engines (Apple Intelligence state; Ollama reachable or off), Permissions (Accessibility · Screen Recording · Reminders · Calendar · Notes, each with a dot or Grant…), Settings…, Quit. No badge; one small dot only when a permission is missing.

## Where the gradient may appear
The icon carries it. Inside the app, exactly twice: the Ollama-state top hairline and the About pane. Never behind the box or the chips, never as an input glow, never in the menu bar. One static glow is permitted: the pre-suggested chip's outline at 40 % accent.

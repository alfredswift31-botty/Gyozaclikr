# Gyozaclikr: the brief (5 Oct 2026)

## The idea, as the owner put it
A pointer-level assistant for the Mac. Select something, a picture or some words, and a small box appears beside the mouse pointer. Type what you want: "what is this?", "change this into a formal writing style", "send this to someone@gmail.com in formal style". Apple Intelligence on the Mac does the work. Think of the Chromebook's Select to Search, on macOS, with the on-device model behind it.

## The brief, improved
**Gyozaclikr turns any selection on the screen into a question or a command, answered on the Mac.**

- **One gesture.** A global shortcut (tap for the current selection; hold for a screen region). Optional: a small pill after a drag selection, like PopClip. Always: a Services-menu entry that needs no permission.
- **Two kinds of input.** Text from any app, read through Accessibility with a copy fallback. A region of the screen, captured as an image, with the words in it read by Live Text.
- **Two tiers of asking.** A row of chips for the eight things people do most (Fix, Shorter, Formal, Casual, Summarise, List, Reply, Remind), each a fixed and tested prompt, reachable by ⌘1–⌘8. Free text for everything else, parsed first by the app for connectors (mail, reminder, event, note, search) and only then by the model, with a confirmation card before anything leaves the box.
- **One engine by default.** Apple's on-device Foundation Model: text on macOS 26, text and images on macOS 27. The engine layer is GyozaYap's, carried over: the availability messages, the error mapping, the structured output. The owner's local Qwen3-VL through Ollama is the labelled second engine for image questions the 3B model can't answer well. Nothing leaves the Mac unless the user picks an engine that does, and the box says so.
- **Honest about facts.** The model transforms what is selected; it is not a source of facts. GyozaYap measured it inventing action items against explicit instructions. Extraction asks for a quote behind every item and drops items whose quote is not in the selection. "Who is this person" and "where can I buy it" are refused with a reason, not answered badly.
- **The box.** A 360-pt card on the 8-pt grid, anchored to the selection, with a quote or a thumbnail of what was selected, the chip row, the streaming answer, and the actions: Replace, Copy, Insert below, Send…. Quiet, typographic, one accent; the icon's gradient appears only on the Ollama state's top edge and the About pane.
- **Read-write, with undo.** Local transforms replace or insert without confirmation and can be undone. Mail, reminders, events and shortcuts always confirm first.

## What it is not
Not a chat window. Not a screen recorder with a timeline. Not a face identifier, a shopping finder or a fact checker. Not a cloud service.

## Why it fits the suite
GyozaYap already runs the same model on this Mac; GyozaVitals shows what it costs. Gyozaclikr is the third use of the same on-device stack, built for the moment between selecting and acting.

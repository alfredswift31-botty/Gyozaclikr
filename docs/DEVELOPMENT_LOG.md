# Gyozaclikr development log

A pointer-level assistant for the Mac: select, summon, ask, act. On-device.

## Releases

| Version | Date | Release |
|---|---|---|

## Research and design (5 Oct 2026)
Three agents researched in parallel: Apple's APIs, the system-integration layer, and the product and the box. Reports in `docs/research/`. The decisive finding: Apple's on-device Foundation Model takes images on macOS 27 (`Attachment`), verified against Apple's documentation data, so the app leads with Apple Intelligence for pictures and keeps the owner's Qwen3-VL via Ollama as the labelled second engine. Decisions: a deterministic chip row plus a pre-router before any free-text goes to the model; quote verification on every extraction (GyozaYap measured the model inventing items); confirmation cards for anything outward; a self-signed certificate rather than ad-hoc signing, because macOS ties Accessibility and Screen Recording grants to the designated requirement. "Who is this person" and "where can I buy it" are refused by design.

## 1.0: the build (5 Oct 2026)
Scaffold: the project file cloned from GyozaVitals (synchronized folders, Swift 5 mode, default MainActor isolation, macOS 26 minimum), `Core/Model.swift` as the contract between modules, the theme shared with the suite plus the box's tokens, Info.plist with every usage string and the Services entry, the apple-events entitlement, CI on GitHub's `xcode-27` preview runner (macOS 27 SDK; `SDK_MACOS27` set by an SDK-conditional build setting) and on `macos-26` for the text-only build. Four agents then built Capture, Engine, Router + Actions and UI against the contract, each with tests, on their own branches; the coordinator wired them.

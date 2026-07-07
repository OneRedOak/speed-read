# sr — build progress

PRD: see conversation / repo root. Reference implementation cloned at `reference/` (Speak11, Unlicense).

## Decisions (Phase 0, 2026-07-06)

| Q | Decision |
|---|---|
| Q-1 Name | **sr** — CLI `sr`, bundle `com.patrickellis.sr`, Keychain item "sr — ElevenLabs API Key", storage `~/Library/Application Support/sr/` |
| Q-2 macOS floor | 14+ (dev machine runs macOS 26.5; no constraint) |
| Q-3 Hotkey dep | `sindresorhus/KeyboardShortcuts` (1 of 2 SPM budget) |
| Q-4 History-ID | Header-first: read `history-item-id` response header from TTS response; fallback to `GET /v1/history?page_size=1` match. **Live verification pending** (needs API key in Keychain). `DELETE /v1/history/{history_item_id}` confirmed in docs. |
| Q-5 Pause semantics | Primary hotkey ⌥⇧/ = speak/stop; secondary ⌥⇧. = pause/resume (per PRD F-2, revisit after use) |
| Q-6 Public release | Undecided; keeping CHANGELOG from day one, code written for strangers |
| Build toolchain | Pure SwiftPM + `scripts/build-app.sh` assembling `sr.app` (only CLT installed, no Xcode — works; signing/notarization deferred to Phase 3) |

## Phase 0 audit findings (§6.3)

- **Pasteboard restore: NO.** `Speak11.swift handleHotkey()` posts ⌘C via CGEvent and sleeps 200 ms; `speak.sh` reads `pbpaste`. Nothing snapshots or restores the prior clipboard. Confirms P-3 need.
- **Content on disk: YES.** `speak.sh` writes the full normalized text to `$TMPDIR/speak11_text` (for respeak position tracking) and never deletes it until next run. sr must keep respeak state in memory only.
- **tts.log: content-free** — `tts_server.py` logs `text_len=` only; `speak.sh` logs voice/speed/paths. Exception tracebacks could theoretically embed text; sr logging is content-free by design (P-5).
- **normalize.py temp files: none** (pure stdin→stdout; optional read of `~/.config/speak11/latex_macros.tex`).
- **Install downloads:** python-build-standalone (pinned URL, GitHub) + `mlx-community/Kokoro-82M-bf16` via huggingface_hub — **no checksum verification**. sr adds SHA-256 pinning (P-12).
- **Network endpoints observed in reference:** api.elevenlabs.io only (subscription check + TTS). No telemetry found.
- **Speed:** reference passes `voice_settings.speed` (0.7–1.2) to the API — regenerates on change. sr pins API speed 1.0, client-side time-stretch (F-8).
- **ElevenLabs voice_settings.speed confirmed in current API docs** (default 1.0) — safe to omit/pin.

## Ported-with-gratitude map

| Reference | sr location |
|---|---|
| `normalize.py` (1219 lines: source detect, markdown/latex/pdf front-ends, phases 0/A/B/C/D) | `Sources/SRCore/Normalizer/` |
| `speak.sh` fallback logic (429/network → local), sentence pause `pause/speed` scaling | `SynthesisPipeline` + `PlaybackEngine` |
| `Speak11.swift` CGEvent tap (keycode 44 ⌥⇧, tap re-enable on timeout), ⌘C simulation (vk 8, 200 ms settle) | `HotkeyManager` / `SelectionCapture` (via KeyboardShortcuts for the hotkey itself) |
| `speak11-audio.swift` queue player semantics | `PlaybackEngine` (AVAudioEngine) |
| Voice/model preset lists, ElevenLabs defaults 0.50/0.75/0.00/boost-on | `Providers/ElevenLabs.swift` |
| `tts_server.py` | Phase 2: adapted daemon (Unix socket + token) |

## Status

- [x] Phase 0 — recon, audit, decisions (this file)
- [ ] Phase 0 spike B — live API history-item-id verification (**blocked on user putting key in Keychain**)
- [ ] Phase 1 — MVP: F-1, F-2, F-3 (ElevenLabs only), F-4, F-5, F-6 minimal, F-8, P-1, P-2, P-3, P-5, P-11 — in progress
- [ ] Phase 2 — privacy hardening + Kokoro + cache
- [ ] Phase 3 — transport polish, sign/notarize, v1.0
- [ ] Phase 4 — automations (CLI → Shortcuts → MCP → scheme)

## Deviations from PRD

- None yet.

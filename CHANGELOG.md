# Changelog

## Unreleased

- Phase 2: history auto-delete janitor (P-6, on by default); content-addressed
  audio cache with LRU/TTL/purge/no-cache toggle (P-10/F-9); per-app routing
  rules with password managers blocked by default + Local-Only backend mode
  (P-8); Kokoro local TTS — hardened daemon (Unix socket, per-launch token,
  content-free logs), supervised with backoff, uv-managed installer with
  pinned mlx-audio 0.4.4 and SHA-256-verified model (P-9/P-12); Auto mode
  cloud→local fallback (T-7 wiring); cost controls: exact billed-character
  ledger, 30k/day budget with warning/hard-stop/override, large-read
  confirmation (C-1..C-4).

- Phase 0: cloned Speak11 reference, completed §6.3 privacy audit, recorded
  decisions (name: sr; KeyboardShortcuts dep; history-ID mechanism
  header-first pending live verification). See PROGRESS.md.
- Phase 1 (in progress): SwiftPM scaffold; ElevenLabs streaming provider with
  API speed pinned at 1.0 (F-8); Keychain-only key storage (P-1); AX-first
  selection capture with pasteboard save/restore and concealed-content
  refusal (P-2/P-3/P-4); content-free logging (P-5); sentence chunking with
  bounded-concurrency synthesis (F-5); AVAudioEngine playback with live
  0.5–3.0× pitch-preserving speed (F-8); MenuBarExtra UI with transport,
  speed slider, voice/model pickers, credits display.

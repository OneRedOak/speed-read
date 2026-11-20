# Changelog

## Unreleased

- Forensic performance, reliability, ElevenLabs, and UI audit pass:
  - **Audio & playback**: moved MP3/WAV decoding 100% in memory via `AudioToolbox` (zero `/tmp` audio files on disk); upgraded WSOLA time-stretch to SIMD `vDSP_conv` normalized cross-correlation with raised-cosine cross-fades and silence-cadence preservation (eliminates plosive/onset artifacts and speeds up stretching); added conservative edge-silence capping and 5 ms seek de-click micro-fades; replaced `playerTime × renderRate` estimation with exact per-buffer `ScheduledSpan` frame tracking (zero drift over long reads); fixed task cancellation on stop/seek, paused-state engine wakeups, and Bluetooth reconfiguration retries.
  - **Local Kokoro & pipeline**: serialized local pipeline requests so chunk 0 always reaches the GPU first (eliminates head-of-line inversion); passed the user's selected voice to daemon warmup (defaulting new installs to `af_heart`); bounded Metal cache & GC flushes instead of flushing every sentence; tightened daemon readiness polling to 100 ms and added 5 MB log rotation.
  - **ElevenLabs cost & quality**: added free `previous_text` prosody stitching across sentences (0 extra credits, never leaks future unsent chunks); surfaced `0.5×` vs `1×` credit multipliers in model menus and large-read estimates; switched to a dedicated ephemeral `URLSession` (HTTP/2 pooling, zero disk cache/cookies) with single fast transient retries; added `Standard (128 kbps)` vs `Compact (64 kbps)` audio quality and Stability/Similarity controls; cached Keychain reads in memory.
  - **Core fixes & UI**: fixed `CostLedger` thread-safe timezone-aware date stamping, `HistoryJanitor` earliest-ready scheduling, `AudioCache` immediate pending-write purge and async LRU mtime touches, `SelectionCapture` private `CGEventSource` (no hotkey modifier bleed into ⌘C) and untouched-clipboard preservation, dynamic `rules.json` reload, and ASCII fast-paths in `Normalizer`; added scrubbable progress bar, sentence steppers, live status pill, instant 5-chip speed presets (`1×`–`2.5×`), persistent actionable error banners, and expanded Settings controls.

- Redesigned the reader with clearer playback grouping, a wider panel, readable
  status text, and aligned voice/model menus. Local mode shows the installed
  Kokoro model; privacy and storage controls moved to Settings. Corrected the
  1.25× label and made slider increments match the speed presets. Added optional
  isolated SwiftUI renders for light/dark, Cloud/Auto/Local layouts.

- Updated the offline runtime to MLX Audio 0.5.7 with a regenerated hashed
  dependency lock. Heart and Bella lead the local voice list. Updated the
  local audio cache version so old runtime output is regenerated.

- Added Eleven v4 and v4 Turbo, with v4 Turbo as the default for new settings.
  v4 requests omit unsupported legacy voice settings; existing saved model
  choices and local playback-speed controls are preserved.

- Fixed jarring pauses between sentences on the local voice at faster playback
  rates: Kokoro bakes ~0.4 s leading / ~0.6 s trailing silence into every
  generated segment, so each boundary carried ~1 s of dead air on top of the
  configured sentence pause. The daemon now trims edge silence per segment
  (keeping a 60 ms natural pad), and the local cache key was bumped so
  previously cached untrimmed audio is re-synthesized.

- Audit hardening: unified GUI/CLI backend routing so Local never reaches the
  cloud and Cloud never silently falls back; added AX protected-content and
  delayed-copy clipboard safeguards; enforced per-chunk cloud budgets and a
  bounded input size; made shutdown await history, installer, and daemon work;
  surfaced Keychain, install, decode, engine, and invalid-audio failures.
- Playback now accounts for pending decode/render/buffer work, pauses its
  content clock during underruns, and stores encoded timeline audio instead of
  unbounded PCM. Decode, resample, normalization, and chunking work runs off the
  main actor.
- Hardened the Kokoro daemon and installer with a fully hashed dependency lock,
  exact Python/model pins, verified-manifest-only startup, bounded connections,
  disconnect checks, safe Unix-socket writes, watchdogs, cancellation cleanup,
  and content-free errors.
- Added synthesis single-flight, debounced cache maintenance, CLI parser and
  daemon tests, warning-free strict-concurrency verification, and macOS CI.

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

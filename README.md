# sr

A privacy-first, automation-ready text-to-speech utility for macOS.
Select text in any app, press **⌥⇧/**, hear it read aloud in a modern AI
voice. Rebuilt from the public-domain [Speak11](https://github.com/smcantab/speak11)
reference implementation as a single native Swift app.

## Status

Phase 1 (MVP). See `PROGRESS.md` for the phase plan and `CHANGELOG.md` for
history.

## Usage

- **⌥⇧/** — speak the current selection; press again to stop
- **⌥⇧.** — pause / resume
- Menu bar icon — transport, live speed slider (0.5×–3.0×, pitch-preserving,
  never re-generates audio), voice & model pickers, credits display,
  "Speak Clipboard", hotkey recorders, API key entry

## Build

Requires macOS 14+, Apple Silicon, and Swift 6 (Command Line Tools are
sufficient — no Xcode needed).

```sh
make app      # builds dist/sr.app
make run      # builds + launches
make install  # builds + copies to /Applications + launches
make test     # unit + normalization parity tests
```

## Running & restarting

sr is a menu bar app (the waveform icon); it has no Dock icon. After
quitting it ("Quit sr" at the bottom of the menu), restart it any of
these ways:

- **Spotlight / Launchpad** — if installed via `make install`, hit ⌘Space,
  type "sr", return. This is the recommended setup.
- **Finder** — double-click `/Applications/sr.app` (or `dist/sr.app` in
  the repo if you haven't installed it).
- **Terminal** — `open /Applications/sr.app`, or from the repo:
  `open dist/sr.app` / `make run` (rebuilds first).

Only run one copy at a time: if you use both the repo build and the
/Applications copy, quit one before launching the other.

Permissions (Accessibility) and the Keychain entry follow the app's
signing identity, not its location — moving or rebuilding the app does
not re-prompt.

To start sr automatically at login: System Settings → General →
Login Items & Extensions → "+" → select `/Applications/sr.app`. (A
built-in "Launch at login" toggle via SMAppService is planned for
Phase 3.)

First launch prompts for **Accessibility** permission (needed for the
global hotkey and reading the selection; sr reads the selection via the
Accessibility API first and only falls back to a simulated ⌘C — with full
clipboard save/restore — where AX is unavailable).

## API key

The ElevenLabs API key lives **only** in the macOS Keychain
(item: `sr — ElevenLabs API Key`). Add it from the menu bar (Settings →
"Add ElevenLabs API Key…") or:

```sh
security add-generic-password -a elevenlabs -s "sr — ElevenLabs API Key" -w
```

Recommended account hardening (one-time, see PRD P-7): opt out of training
under Terms & Privacy → Data Use; use a dedicated key scoped to
Text-to-Speech + User Read only.

## Network endpoints (complete list)

sr never phones home. The complete list of hosts it may ever contact:

| Host | When |
|---|---|
| `api.elevenlabs.io` | Cloud synthesis, voice list, credit display, history auto-delete |
| `api.github.com` | Manual "Check for updates" only (Phase 3+) |
| `huggingface.co` | Explicit local-model (Kokoro) install only (Phase 2+) |

No analytics, no crash uploaders, no auto-update phone-home. Logging is
content-free by design: `~/Library/Logs/sr/sr.log` records counts,
latencies, and HTTP statuses — never the text being spoken.

## Privacy properties

- Keychain-only credentials; the UI shows at most the last 4 characters
- Accessibility-API-first capture; ⌘C fallback snapshots and restores the
  full pasteboard (images, RTF, files) and verifies via `changeCount`
- Concealed pasteboard items (`org.nspasteboard.ConcealedType`, the
  password-manager standard) are refused: never spoken, cached, logged,
  or transmitted
- API playback speed is pinned at 1.0; speed changes are client-side
  time-stretch — instant, free, and cache-friendly

## License

Built from the Unlicense'd Speak11; this repository keeps the same
public-domain spirit (license file TBD before any public release).

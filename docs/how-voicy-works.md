# How Voicy works

Notes from inspecting the locally installed Voicy 3.0.0
(`/Applications/Voicy.app`). I unpacked `Contents/Resources/app.asar` and read
its compiled JavaScript, but did not run it or capture its network traffic.
This file is a reference for building Murmur; it copies none of Voicy's code
or assets.

## Packaging

- **Electron app.** One cross-platform codebase (package name
  `voicywindowsapp`, bundle id `com.example.voicyforwindows`) ships to macOS,
  Windows and Linux. `main.js` bootstraps `dist/src/main/bootstrap.js`, and
  platform adapters live in `dist/src/main/platform/{darwin,win32,linux}`.
- **Native helpers** sit in `app.asar.unpacked`:
  - `@fugood/node-whisper-*`: a whisper.cpp Node binding, patched by Voicy,
    used for offline transcription.
  - `koffi`: a foreign-function interface. On macOS Voicy uses it to call
    CoreGraphics and Accessibility directly from JavaScript.
  - `ffmpeg-static`: decodes audio files for file transcription.
  - `voicy-media-control`: pauses and resumes system media while recording.
- **Updates and telemetry:** updates come from GitHub releases through
  `electron-updater`. Sentry, Mixpanel and PostHog are bundled for telemetry,
  and accounts sign in with Google or Microsoft OAuth.

## The dictation pipeline

```
global shortcut ──► capture context ──► record ──► transcribe ──► (AI format) ──► paste
 (toggle / mouse)    app, window,       mic →       cloud WS or     server-side      clipboard +
                     caret text         PCM 16 kHz  local whisper   LLM pass         ⌘V via CGEvent
```

1. **Trigger** (`main/shortcuts/recording.js`): a toggle hotkey registered
   through Electron's `globalShortcut`, or a mouse button caught by a
   CGEventTap (`platform/darwin/mouse-tap.js`). A rapid-press guard stops
   accidental double toggles. While recording, Esc is registered globally to
   cancel.
2. **Context** (`platform/darwin/input.js`): before recording starts, Voicy
   reads the frontmost app and focused window title through
   `NSWorkspace`/`AXUIElement`. It then reads **64 characters on each side of
   the caret** with `AXSelectedTextRange` and `AXStringForRange`, and skips
   secure text fields. For Chromium/Electron targets it sets
   `AXManualAccessibility` so the target exposes its accessibility tree.
   `shared/caret-context.js` turns that text into facts: whether the text
   continues a sentence, whether text follows the caret, and whether
   leading or trailing spaces are needed.
3. **Recording** (`renderer/recording/audio/recorder/*`): the HUD window runs
   `getUserMedia`. An AudioWorklet emits 16 kHz PCM, and a waveform is drawn
   from the level. Silence detection auto-stops after N seconds of low RMS
   (default 30 s). If no sound arrives within 8 s, a "mic is silent" dialog
   appears.
4. **Transcription.** Three paths:
   - **Streaming (default):** PCM chunks go over a WebSocket (`/transcribe`)
     to Voicy's servers, with acknowledgements, reconnects that replay
     buffered audio, failover between servers, and a batch fallback.
     According to the timing logs, the server runs VAD, then transcription,
     then an AI formatting pass.
   - **Batch upload:** a WebM upload to endpoints such as
     `/upload-pishi-groq`. The endpoint name suggests Groq-hosted Whisper
     plus an LLM.
   - **Local:** whisper.cpp runs NVIDIA **Parakeet TDT 0.6B v3** in an
     Electron `utilityProcess`. A "local agreement" algorithm decodes
     overlapping passes while you speak, and the transcript text can then go
     through the server's formatting pass.
5. **Formatting** happens on the server, driven by settings:
   paragraphs, lists, filler removal, a "context-aware" flag (the target app
   name is sent), custom modes (user-written prompts such as "email" or
   "notes"), and a personal dictionary of up to 600 characters.
6. **Insertion** (`main/services/paste.js`, `ipc/transcription.js`):
   - Silence hallucinations (`"you"`, `"Thank you."`) are dropped.
   - Text replacements are applied (whole-word, case-insensitive).
   - Spacing is adjusted to the caret.
   - The text is written to the clipboard, and ⌘V is posted with
     `CGEventCreateKeyboardEvent` + `CGEventPost` (key code 9 + command
     flag). This requires Accessibility permission.
   - If "preserve clipboard" is on, the previous clipboard contents are
     restored about 1 s later, but only if nothing else changed them.
7. **Edit mode** (`main/shortcuts/rewrite/*`): a second shortcut copies the
   selection with a synthetic ⌘C (snapshotting and restoring the clipboard).
   You then speak an instruction, and the selection plus the audio go to an
   `/upload-pishi-editing` endpoint. The result is pasted over the
   selection, or shown in a bubble when no editable field is focused.
8. **Extras:**
   - history with retry of failed audio
   - a "paste last transcript" shortcut
   - quick language switching (shortcuts 1–9)
   - saved rewrite commands
   - file transcription (ffmpeg)
   - usage limits and subscriptions
   - referrals and a mobile app link

## What Murmur keeps, and what it changes

| Concern | Voicy | Murmur |
|---|---|---|
| Runtime | Electron (~250 MB) | Native Swift/AppKit/SwiftUI (~1.5 MB) |
| Shortcut | Electron `globalShortcut` | Carbon `RegisterEventHotKey` (tap = toggle, hold = push-to-talk) + lone-modifier hold (Right ⌥) |
| Default engine | Voicy cloud (WebSocket) | Apple Speech, on-device and streaming |
| Other engines | Local Parakeet via whisper.cpp | Any OpenAI-compatible Whisper API (Groq, OpenAI), or your own `whisper-cli` |
| AI formatting | Voicy's server-side LLM | Optional Claude pass with your own API key; edit-by-voice uses Claude |
| Context | App, title, caret ±64 chars | Same, through the Accessibility API |
| Insertion | Clipboard + CGEvent ⌘V, restore clipboard | Same, plus a layout-aware V key and a transient-pasteboard marker |
| Account, telemetry, updates | Required account, Sentry/Mixpanel/PostHog, auto-update | None: no account, no telemetry |

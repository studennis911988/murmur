# Murmur

Murmur is a menu-bar dictation app for macOS. Hold a key, speak, and the
text appears wherever your cursor is: Notes, Slack, your browser, your code
editor, the terminal. You can also select text and say how to change it.

- **Works in any app.** It pastes at the cursor and puts your clipboard back
  afterwards.
- **Private by default.** Speech recognition runs on your Mac with Apple
  Speech or local models. No account, no telemetry.
- **Good at English and Taiwanese Mandarin, including mixed sentences.** This
  was measured, not assumed; see [Choosing a speech engine](#3-choose-a-speech-engine).
- **Optional AI with Claude.** It can clean up punctuation and filler words
  and apply your own modes (e.g. "write it as an email"). It can also rewrite
  selected text by voice.
- **Small and native:** about 1.5 MB, written in Swift.

Murmur started as a native, privacy-first take on [Voicy](https://usevoicy.com)'s workflow.

---

## 1. Install

You need **macOS 14 (Sonoma) or newer**. It's tested on Apple Silicon.

1. Install Apple's command line tools, which include Swift and git. Skip
   this if `swift --version` already works.

   ```bash
   xcode-select --install
   ```

2. Get the code and build it. This builds `Murmur.app`, copies it to
   `/Applications`, and starts it.

   ```bash
   git clone https://github.com/<you>/murmur.git
   cd murmur
   make install
   ```

   A **waveform icon** appears in the menu bar, and the Setup window opens.

## 2. Grant permissions

In Murmur's **Setup** window, grant:

| Permission | Why | How |
|---|---|---|
| **Microphone** | To hear you | Click **Allow** |
| **Accessibility** | To paste into other apps and read the text around the cursor | Click **Open Settings**, then switch **Murmur** on under Privacy & Security → Accessibility |
| **Speech Recognition** | Only if you use the Apple Speech engine | Click **Allow** |

Without Accessibility, Murmur still transcribes, but it only copies the text
to the clipboard for you to paste.

## 3. Choose a speech engine

Pick one. You can switch at any time in **Settings → Transcription**.

### Option A: Local models (recommended)

These are the most accurate for English and Mandarin, run fully offline, and
take about 3 minutes to set up.

```bash
brew install whisper-cpp            # the engine (needs Homebrew: https://brew.sh)
scripts/setup-models.sh --use       # downloads ~2.3 GB of models and switches Murmur to them
```

This sets up two models:

- **Parakeet TDT v3** for English. It's fast: about 0.4 s after you stop
  talking.
- **Breeze-ASR-25** for Auto-detect and Mandarin. It handles Taiwanese
  Mandarin and mixed sentences like 「明天的 meeting 改到下午」, and takes
  about 1–2 s.

Switch languages from the menu bar: **Language → Auto / English / 中文（台灣）**.
Leave it on **Auto** if you mix languages.

If disk space matters, use `scripts/setup-models.sh turbo --use` instead
(Whisper large-v3-turbo, 574 MB). It's less accurate for Mandarin.

### Option B: Apple Speech (nothing to download)

Apple Speech shows a live preview while you talk, but it's much less
accurate (see the table below).

1. Turn on **System Settings → Keyboard → Dictation**. Apple's speech engine
   refuses to run without it.
2. In the same pane, add the languages you dictate in, so they work
   offline.
3. In Murmur, choose **Settings → Transcription → Engine → Apple Speech**.

### Option C: A cloud Whisper API

Use this if you want maximum accuracy without downloading models. In
**Settings → Transcription**:

1. Choose **Whisper API**.
2. Pick the **Groq** or **OpenAI** preset.
3. Paste your API key. It's stored in your macOS Keychain.

Your audio is sent to that provider.

### How the engines compare

Measured on an M4 Pro with real speech: LibriSpeech English, and NTU lecture
recordings in Taiwanese Mandarin with English terms. Details are in
[eval/README.md](eval/README.md).

| Engine | English error rate | Taiwanese Mandarin error rate | Time after you stop |
|---|---|---|---|
| Parakeet TDT v3 (local) | **2.0%** | — (no Chinese) | **~0.4 s** |
| Breeze-ASR-25 (local) | 2.5% | **3.8%** | ~1–2 s |
| Whisper large-v3-turbo (local) | 3.4% | 9.4% | ~1 s |
| Apple Speech | 9.8% | 29–42% | instant (live preview) |

For Chinese, Murmur always outputs Traditional characters when your
language is 中文（台灣） or your Mac prefers Traditional Chinese.

## 4. Dictate

| To… | Do this (defaults) |
|---|---|
| Dictate | **Hold Right ⌥** (Option), speak, release |
| Dictate hands-free | Tap **⌥Space** to start, tap again to finish |
| Cancel | **Esc** |
| Edit selected text by voice | Select text, press **⌥⇧Space**, say e.g. "make this more polite" (needs Claude) |
| Write something new by voice | **⌥⇧Space** with nothing selected: "write a short reply saying I'll be late" |
| Paste the last transcript again | **⌃⌥V** |

While you talk, a small bar at the bottom of the screen shows a waveform.
Click ✓ to finish or ✕ to cancel.

The menu bar icon also gives you:

- the language;
- the AI polish mode;
- recent dictations (click one to copy it);
- **Transcribe Audio File…** for voice memos and other recordings.

You can change every shortcut in **Settings → General**.

## 5. Optional: AI with Claude

You need an Anthropic API key from console.anthropic.com.

1. In **Settings → AI**, paste the key.
2. Choose an **AI polish** mode (also available in the menu bar):
   - **Off:** inserts exactly what was heard.
   - **Clean up:** fixes punctuation and filler words, keeps only your
     self-corrections ("at 3, no, 4pm" becomes "at 4pm"), and adds
     paragraphs and lists.
   - **Custom modes:** your own instructions on top of Clean up. Email,
     Bullet notes, and Prompt come as examples.
3. **⌥⇧Space**, edit selected text by voice, always uses Claude.

The default model is `claude-opus-5-5` at low effort. Choose
`claude-haiku-5-5` for the fastest responses. If Claude is unavailable,
Murmur pastes the raw transcript and tells you why.

**What gets sent to Anthropic:**

- the transcript;
- for edits, the selected text;
- the app name and window title (you can turn this off in Settings → AI).

## Vocabulary and replacements

In **Settings → Vocabulary**:

- **Dictionary:** names and jargon to spell correctly, e.g. "Kubernetes,
  Figma, 王小明". Every engine gets them as hints.
- **Replacements:** a spoken phrase becomes fixed text, e.g. "my email"
  becomes your address.

## Updating

```bash
git pull
make install
```

After each rebuild, macOS treats Murmur as a new app. Open *System Settings →
Privacy & Security → Accessibility*, select Murmur, remove it with **−**,
then add `/Applications/Murmur.app` again with **+**. (Toggling it off and
on usually works too.)

To avoid re-granting after every rebuild, sign builds with a fixed local
certificate:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**.
2. Name it `Murmur Local`, keep Identity Type *Self Signed Root*, and set
   Certificate Type to *Code Signing*.
3. Build with `SIGN_ID="Murmur Local" make install` from then on.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Text is copied but not pasted | Grant Accessibility, or re-grant it after a rebuild (see [Updating](#updating)) |
| "Apple Speech needs macOS Dictation switched on" | Turn on System Settings → Keyboard → Dictation, or use local models |
| "whisper-cli not found" / "parakeet-cli not found" | `brew install whisper-cpp` |
| "Choose a local model" | Run `scripts/setup-models.sh --use` |
| Shortcut does nothing; Settings → General shows "…is taken" | Another app owns that shortcut; record a different one |
| Holding Right ⌥ does nothing | Accessibility is needed to watch the key. After granting it, wait 2 s or restart Murmur |
| "No sound — check the microphone" | Choose the right input in System Settings → Sound → Input |
| Chinese comes out in Simplified | Set Language to 中文（台灣）, or use Breeze-ASR-25 |
| A dictation failed | The audio is kept: **Settings → History → Retry** |

To see logs:

```bash
log stream --level debug --predicate 'subsystem == "dev.murmur.app"'
```

## Uninstall

```bash
pkill -x Murmur; rm -rf /Applications/Murmur.app "$HOME/Library/Application Support/Murmur"
defaults delete dev.murmur.app
```

API keys are in Keychain Access under "Murmur". Remove them there if you
saved any.

## Privacy

| Setting | What leaves your Mac |
|---|---|
| Local models, or Apple Speech with "Keep audio on this Mac" | Nothing |
| Whisper API | Your audio, sent to the provider you chose |
| AI polish / edit by voice | The text, and optionally the app name and window title, sent to Anthropic |

History and failed recordings stay in `~/Library/Application Support/Murmur`.
You can turn history off or clear it in Settings → History.

---

## For developers

```bash
make check    # self-checks for the text logic (no Xcode needed)
make app      # build build/Murmur.app
make run      # build and open it
```

| Path | Contents |
|---|---|
| `Sources/MurmurCore` | Pure logic: replacements, smart spacing, transcript cleanup, Chinese script, Claude prompts, WAV encoding |
| `Sources/Murmur/DictationController.swift` | Orchestrates context → record → transcribe → polish → paste |
| `Sources/Murmur/Audio.swift` | Microphone capture, 16 kHz resampling, levels, silence auto-stop, device-change handling |
| `Sources/Murmur/Transcription.swift` | Apple Speech, Whisper API, whisper.cpp / parakeet-cli engines and model routing |
| `Sources/Murmur/Insertion.swift` | Accessibility context, clipboard-preserving paste, ⌘C capture |
| `Sources/Murmur/Hotkeys.swift` | Global shortcuts and modifier push-to-talk |
| `Sources/Murmur/Claude.swift` | Anthropic Messages API client |
| `Sources/Murmur/HUD.swift`, `SettingsView.swift`, `AppDelegate.swift` | User interface |
| `eval/` | Speech-engine benchmark (`python3 eval/fetch_data.py && python3 eval/run_eval.py`) |

The app binary also has a headless command line:

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --help
/Applications/Murmur.app/Contents/MacOS/Murmur --transcribe memo.m4a
```

### Model sources

| File | Source |
|---|---|
| `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF) (NVIDIA Parakeet TDT 0.6B v3, CC-BY-4.0) |
| `ggml-breeze-asr-25-q8_0.bin` | [alan314159/Breeze-ASR-25-whispercpp](https://huggingface.co/alan314159/Breeze-ASR-25-whispercpp), a whisper.cpp conversion of [MediaTek-Research/Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) (Apache-2.0). It is byte-identical to an independent conversion by talkyon; SHA-256 values are pinned in `scripts/setup-models.sh` |
| `ggml-large-v3-turbo-q5_0.bin` | [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) (OpenAI Whisper, MIT) |

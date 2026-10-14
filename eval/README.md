# Speech-to-text evaluation (en-US, zh-TW)

How well each engine Murmur can use handles English and Taiwanese Mandarin,
measured on an Apple M4 Pro (24 GB) running macOS 15.7 on 2026-10-14. Full
tables are in [results/report.md](results/report.md); per-clip transcripts are
cached in `results/raw/` (ignored by git).

## Data

| Set | Clips | Speech |
|---|---|---|
| `en-libri` | 40 | Real read English: LibriSpeech test-clean, 20 speakers |
| `zh-tw-lecture` | 40 | Real Taiwanese Mandarin: NTU ML2021 lectures. 15 clips mix in English technical terms |
| `en-dictation` | 12 | Synthetic dictation-style sentences (macOS "Samantha") |
| `zh-tw-dictation` | 12 | Synthetic dictation-style sentences, some with English words (macOS "Meijia") |

Reproduce:

```bash
python3 eval/fetch_data.py
python3 eval/run_eval.py
```

To compare cloud engines, add a provider key: extend `ENGINES` in
`run_eval.py` with Murmur's `--engine cloud` CLI path.

## Results

Error rates are WER for English. For Mandarin they are MER: Chinese
characters plus English words as tokens, after converting to Traditional.
Time is seconds per clip including model load (clips average ~8 s in
`en-libri` and ~3 s in `zh-tw-lecture`).

| Engine | en-libri WER | zh-tw-lecture MER | zh-TW written in Simplified | s/clip (en / zh) |
|---|---|---|---|---|
| **Parakeet TDT 0.6B v3** (q8_0) | **2.0%** | n/a (no Chinese) | n/a | **0.36** / n/a |
| **Breeze-ASR-25** (q8_0) | 2.5% | **3.8%** | 0% | 1.63 / 1.39 |
| Whisper large-v3-turbo (q5_0), Traditional prompt | 3.4% | 9.4% | 10% | 0.94 / 0.90 |
| Whisper large-v3-turbo (q5_0) | 3.4% | 10.4% | **75%** | 0.94 / 0.89 |
| Apple Speech, on-device | 9.8% | 42.4% (29.5% excluding 7 empty outputs) | 0% | 0.52 / 0.33 |

On the synthetic dictation sets every engine scored ≤ 6% (turbo had 1.2%
WER in English; Breeze had 0.4% MER in zh-TW against Apple's 3.2%). Clean
TTS speech flatters every engine, so weight the real-speech columns.

## Findings

1. **For Taiwanese Mandarin, use Breeze-ASR-25.** Its error rate is less than
   half of Whisper turbo's, its output is natively Traditional, and it keeps
   English terms such as "decoder" and "bleu score". Apple Speech fails on
   this material: it returned nothing for 7 of the short, mid-sentence lecture
   clips, and it garbled code-switched terms elsewhere ("max" →
   "妹子", "gradient descent" → "一點Decent").
2. **Force Breeze to "zh", even for English.** On the same 12 English clips,
   Breeze run with `-l zh`, `-l auto` and `-l en` all scored 2.0% WER. On
   code-switched Mandarin, `-l en` scored worse (16.9% vs 11.9%). Murmur
   therefore always runs Breeze as `zh`.
3. **For English, use Parakeet TDT v3.** It had the lowest WER and was about
   4.5× faster than Breeze. It is run with `parakeet-cli`, not `whisper-cli`.
4. **Whisper writes Simplified Chinese for zh unless prompted.** Turbo
   answered 75% of Taiwanese clips (100% of the dictation clips) in
   Simplified. A Traditional prompt (`以下是繁體中文的句子。`) cut that to
   10–17%. Murmur adds that prompt for zh-TW and then converts any remaining
   Simplified-only characters to Traditional.
5. **Apple's server option changed nothing.** With the on-device models
   installed, outputs were byte-identical to on-device on every clip.
6. **Model load is cheap; keeping the model resident wouldn't help much.**
   Load is 0.15–0.4 s per run (cold minus warm). Launching whisper.cpp per
   dictation is fine; a resident `whisper-server` would save at most that.
7. **Apple still has the best live experience.** It streams a preview while
   you talk, so text is ready about 0.2 s after you stop. Local models start
   only when you stop: ~0.4 s for Parakeet, ~1–2 s for Breeze on a 10 s
   dictation.

## Caveats

- The real Mandarin set is lecture speech: one speaker and a technical
  domain. Your own voice and microphone are the real test.
- LibriSpeech is read audiobook speech, which is easier than casual
  dictation.
- English normalization is simple (lowercase, punctuation removed), so
  "standup" vs "stand-up" counts as an error for every engine.
- Script normalization uses ICU's Hans→Hant transform, plus a few Taiwan
  variants.
- The Breeze-ASR-25 ggml file is a community conversion. Two independent
  uploads (alan314159, talkyon) are byte-identical, which corroborates it,
  but it is not an official MediaTek release.
- Cloud APIs (Groq, OpenAI) were not measured: no API key was available.

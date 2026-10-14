#!/usr/bin/env python3
"""Builds the speech-to-text evaluation sets under eval/data/.

Sets (each a directory of 16 kHz mono WAVs plus manifest.jsonl):
  en-libri       real read English speech, LibriSpeech test-clean (40 clips,
                 at most 2 per speaker)
  zh-tw-lecture  real Taiwanese Mandarin lectures with English code-switching,
                 NTU ML2021 (ky552/ML2021_ASR_ST test split, 40 clips)
  en-dictation   dictation-style sentences, macOS "Samantha" voice (synthetic)
  zh-tw-dictation  dictation-style sentences, macOS "Meijia" voice (synthetic)

Real-speech clips are sampled through the Hugging Face dataset viewer API, so
no full dataset is downloaded.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
API = "https://datasets-server.huggingface.co/rows"

EN_DICTATION = [
    "Hey Sarah, can we move tomorrow's standup to the afternoon? I have a dentist appointment in the morning.",
    "Please review the pull request before lunch and let me know if the migration script looks safe.",
    "Revenue grew this quarter, mostly from enterprise customers in Europe.",
    "Remind me to call the landlord about the leaking faucet in the kitchen.",
    "I think the bug is in the cache invalidation logic, not in the API handler.",
    "Thanks for the quick turnaround. The new design looks great on mobile.",
    "Let's schedule a one-on-one next Wednesday to talk about your career goals.",
    "Our flight lands in Tokyo in the evening, so we should book a hotel near the station.",
    "Could you send me the slides from yesterday's presentation and the link to the recording?",
    "We need to rotate the API keys before Friday and update the deployment documentation.",
    "Honestly, I'm not sure that approach will scale once we have many more users.",
    "Add milk, eggs, spinach, and avocados to the grocery list.",
]

ZH_DICTATION = [
    "明天早上的會議改到下午，請大家準時參加。",
    "這個 bug 應該是快取失效的問題，不是 API 本身的錯誤。",
    "我下週三要去台中出差，回來再跟你討論這個專案。",
    "請幫我把簡報寄給客戶，並且附上上次的會議紀錄。",
    "今天的天氣很好，我們下午去大安森林公園散步吧。",
    "這一季的營收成長很多，主要來自企業客戶。",
    "記得提醒我打電話給房東，廚房的水龍頭一直在漏水。",
    "我覺得這個 feature 可以先上線，之後再根據使用者回饋調整。",
    "週末要不要一起去吃牛肉麵？我知道一家很好吃的店。",
    "請在星期五之前完成 code review，然後部署到測試環境。",
    "老實說，我不確定這個做法在使用者變多之後還能撐得住。",
    "購物清單加上牛奶、雞蛋、菠菜，還有酪梨。",
]


def fetch_rows(dataset, config, split, offset, length):
    url = f"{API}?dataset={dataset}&config={config}&split={split}&offset={offset}&length={length}"
    with urllib.request.urlopen(url, timeout=60) as response:
        return [r["row"] for r in json.load(response)["rows"]]


def to_wav(source, target):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source, target],
                   check=True, capture_output=True)


def download_clip(url, target, suffix):
    raw = target + suffix
    urllib.request.urlretrieve(url, raw)
    try:
        to_wav(raw, target)
    finally:
        os.remove(raw)


def write_manifest(name, items, language, kind):
    directory = os.path.join(ROOT, name)
    with open(os.path.join(directory, "manifest.jsonl"), "w") as f:
        for item in items:
            item.update(language=language, kind=kind)
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(f"{name}: {len(items)} clips")


def librispeech():
    name, directory = "en-libri", os.path.join(ROOT, "en-libri")
    os.makedirs(directory, exist_ok=True)
    items, per_speaker = [], {}
    for offset in range(0, 2600, 260):
        picked = 0
        for row in fetch_rows("openslr/librispeech_asr", "clean", "test", offset, 100):
            if picked == 4:
                break
            speaker = row["speaker_id"]
            if per_speaker.get(speaker, 0) >= 2 or not 40 <= len(row["text"]) <= 260:
                continue
            per_speaker[speaker] = per_speaker.get(speaker, 0) + 1
            wav = os.path.join(directory, f"{row['id']}.wav")
            if not os.path.exists(wav):
                download_clip(row["audio"][0]["src"], wav, ".flac")
            items.append({"audio": os.path.relpath(wav, ROOT), "reference": row["text"], "source": f"librispeech test-clean {row['id']}"})
            picked += 1
    write_manifest(name, items, "en-US", "real")


def ml2021():
    name, directory = "zh-tw-lecture", os.path.join(ROOT, "zh-tw-lecture")
    os.makedirs(directory, exist_ok=True)
    mixed, chinese = [], []
    for offset in range(0, 14900, 1500):
        for row in fetch_rows("ky552/ML2021_ASR_ST", "default", "test", offset, 100):
            text = row["transcription"]
            compact = re.sub(r"\s+", "", text)
            if not 12 <= len(compact) <= 70:
                continue
            (mixed if re.search(r"[A-Za-z]", text) else chinese).append(row)
    chosen = mixed[::max(1, len(mixed) // 15)][:15] + chinese[::max(1, len(chinese) // 25)][:25]
    items = []
    for index, row in enumerate(chosen):
        wav = os.path.join(directory, f"{index:03d}.wav")
        if not os.path.exists(wav):
            download_clip(row["audio"][0]["src"], wav, ".wav.src")
        items.append({"audio": os.path.relpath(wav, ROOT), "reference": row["transcription"], "source": f"ML2021_ASR_ST test {row['file']}"})
    write_manifest(name, items, "zh-TW", "real")


def tts(name, voice, sentences, language):
    directory = os.path.join(ROOT, name)
    os.makedirs(directory, exist_ok=True)
    items = []
    for index, sentence in enumerate(sentences):
        wav = os.path.join(directory, f"{index:03d}.wav")
        if not os.path.exists(wav):
            aiff = wav + ".aiff"
            subprocess.run(["say", "-v", voice, "-o", aiff, sentence], check=True)
            to_wav(aiff, wav)
            os.remove(aiff)
        items.append({"audio": os.path.relpath(wav, ROOT), "reference": sentence, "source": f"macOS say -v {voice}"})
    write_manifest(name, items, language, "synthetic")


if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    wanted = set(sys.argv[1:]) or {"en-libri", "zh-tw-lecture", "en-dictation", "zh-tw-dictation"}
    if "en-dictation" in wanted:
        tts("en-dictation", "Samantha", EN_DICTATION, "en-US")
    if "zh-tw-dictation" in wanted:
        tts("zh-tw-dictation", "Meijia", ZH_DICTATION, "zh-TW")
    if "en-libri" in wanted:
        librispeech()
    if "zh-tw-lecture" in wanted:
        ml2021()

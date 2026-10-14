#!/usr/bin/env python3
"""Compares speech-to-text engines on the sets built by fetch_data.py.

    python3 eval/run_eval.py                       # every engine, every set
    python3 eval/run_eval.py --engines turbo,breeze --sets zh-tw-lecture

Transcripts are cached in eval/results/raw/<engine>/<set>.jsonl, so reruns
only process what's missing (delete a file to redo it). The summary goes to
eval/results/report.md and eval/results/summary.json.

Metrics
  English  WER: lowercase, punctuation removed, hyphens split.
  zh-TW    MER: CJK characters and Latin words are tokens (the usual metric
           for Mandarin–English code-switching). "raw" scores the output as
           written, so Simplified characters count as errors; "script-norm."
           first converts both sides to Traditional with ICU.
  Latency  cold = whole whisper-cli run including model load (what a
           per-dictation process pays); warm = load time excluded. Apple
           Speech runs in Murmur's file mode; in live use it streams while
           you talk, so only the tail is left when you stop.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
RESULTS = os.path.join(HERE, "results")
RAW = os.path.join(RESULTS, "raw")
MODELS = os.path.expanduser("~/Library/Application Support/Murmur/models")
WHISPER_CLI = os.environ.get("WHISPER_CLI", "/opt/homebrew/bin/whisper-cli")
PARAKEET_CLI = os.environ.get("PARAKEET_CLI", "/opt/homebrew/bin/parakeet-cli")
MURMUR_APP = os.environ.get("MURMUR_APP", os.path.join(os.path.dirname(HERE), "build", "Murmur.app"))
THREADS = str(max(1, min(8, os.cpu_count() - 2)))
ZH_TRADITIONAL_PROMPT = "以下是繁體中文的句子，可能夾雜 English 詞彙。"

SETS = ["en-dictation", "en-libri", "zh-tw-dictation", "zh-tw-lecture"]


def whisper_engine(model, prompt_zh=None, binary=None):
    def run(wav, language):
        if binary:  # parakeet-cli: English/European only, no language or prompt flags
            args = [binary, "-m", os.path.join(MODELS, model), "-f", wav, "-t", THREADS]
        else:
            args = [WHISPER_CLI, "-m", os.path.join(MODELS, model), "-f", wav, "-nt", "-t", THREADS,
                    "-l", language.split("-")[0]]
        if prompt_zh and language.startswith("zh"):
            args += ["--prompt", prompt_zh]
        started = time.monotonic()
        proc = subprocess.run(args, capture_output=True, text=True)
        cold = time.monotonic() - started
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else f"exit {proc.returncode}")
        load = re.search(r"load time =\s*([\d.]+) ms", proc.stderr)
        warm = cold - float(load.group(1)) / 1000 if load else None
        text = " ".join(line.strip() for line in proc.stdout.splitlines() if line.strip())
        return text, cold, warm
    return run


def apple_engine(on_device):
    def run(wav, language):
        with tempfile.TemporaryDirectory() as tmp:
            out, err = os.path.join(tmp, "out.txt"), os.path.join(tmp, "err.txt")
            started = time.monotonic()
            subprocess.run(["open", "-W", "-n", MURMUR_APP, "--stderr", err, "--args",
                            "--transcribe", wav, "--language", language, "--out", out], check=True)
            cold = time.monotonic() - started
            log = open(err).read() if os.path.exists(err) else ""
            if not os.path.exists(out):
                raise RuntimeError(log.strip() or "no output")
            timing = re.search(r"transcribed in ([\d.]+)s", log)
            return open(out).read().strip(), cold, float(timing.group(1)) if timing else None
    return run


ENGINES = {
    "apple-ondevice": {"run": apple_engine(True), "langs": ["en", "zh"], "label": "Apple Speech (on-device)"},
    "apple-server": {"run": apple_engine(False), "langs": ["en", "zh"], "label": "Apple Speech (Apple servers)"},
    "turbo": {"run": whisper_engine("ggml-large-v3-turbo-q5_0.bin"), "langs": ["en", "zh"], "label": "Whisper large-v3-turbo q5_0"},
    "turbo-hant": {"run": whisper_engine("ggml-large-v3-turbo-q5_0.bin", ZH_TRADITIONAL_PROMPT), "langs": ["zh"], "label": "Whisper large-v3-turbo q5_0 + Traditional prompt"},
    "breeze": {"run": whisper_engine("ggml-breeze-asr-25-q8_0.bin"), "langs": ["en", "zh"], "label": "Breeze-ASR-25 q8_0"},
    "parakeet": {"run": whisper_engine("ggml-parakeet-tdt-0.6b-v3-q8_0.bin", binary=PARAKEET_CLI), "langs": ["en"], "label": "Parakeet TDT 0.6B v3 q8_0"},
}


def apple_on_device_default(value):
    """Murmur stores settings as JSON in its defaults domain."""
    payload = ("true" if value else "false").encode().hex()
    subprocess.run(["defaults", "write", "dev.murmur.app", "appleOnDeviceOnly", "-data", payload], check=True)


# ---------------------------------------------------------------- scoring

_hant_binary = None


def to_traditional(lines):
    global _hant_binary
    if _hant_binary is None:
        _hant_binary = os.path.join(RAW, "hant")
        if not os.path.exists(_hant_binary):
            os.makedirs(RAW, exist_ok=True)
            subprocess.run(["swiftc", "-O", os.path.join(HERE, "hant.swift"), "-o", _hant_binary], check=True)
    joined = "\n".join(line.replace("\n", " ") for line in lines)
    out = subprocess.run([_hant_binary], input=joined, capture_output=True, text=True, check=True).stdout
    return out.split("\n")[: len(lines)]


# Taiwan-standard forms for variants ICU's generic Traditional output differs on.
TW_VARIANTS = str.maketrans({"裏": "裡", "臺": "台", "着": "著", "綫": "線", "爲": "為", "衆": "眾", "峯": "峰",
                             "啓": "啟", "麪": "麵", "喫": "吃", "纔": "才", "麽": "麼", "么": "麼"})
CJK = r"㐀-䶿一-鿿豈-﫿"


def tokens(text, chinese):
    text = text.lower().replace("’", "'").replace("-", " ")
    if chinese:
        text = text.translate(TW_VARIANTS)
        found = re.findall(rf"[{CJK}]|[a-z0-9']+", text)
    else:
        found = re.findall(r"[a-z0-9']+", text)
    return [t.strip("'") for t in found if t.strip("'")]


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def score(rows, chinese):
    refs = [r["reference"] for r in rows]
    hyps = [r["hypothesis"] for r in rows]
    result = {}
    variants = [("raw", refs, hyps)]
    if chinese:
        converted = to_traditional(refs + hyps)
        variants.append(("norm", converted[: len(refs)], converted[len(refs):]))
        simplified = sum(1 for h, c in zip(hyps, converted[len(refs):]) if h.translate(TW_VARIANTS) != c.translate(TW_VARIANTS))
        result["simplified_share"] = simplified / len(rows)
    for name, rs, hs in variants:
        edits = sum(edit_distance(tokens(r, chinese), tokens(h, chinese)) for r, h in zip(rs, hs))
        total = sum(len(tokens(r, chinese)) for r in rs)
        result[name] = edits / max(1, total)
    audio = sum(r["audio_seconds"] for r in rows)
    result["cold_rtf"] = sum(r["cold"] for r in rows) / audio
    warm = [r["warm"] for r in rows if r.get("warm") is not None]
    result["warm_rtf"] = sum(warm) / audio if len(warm) == len(rows) else None
    result["cold_mean"] = sum(r["cold"] for r in rows) / len(rows)
    result["warm_mean"] = sum(warm) / len(warm) if warm else None
    result["clips"] = len(rows)
    result["failures"] = sum(1 for r in rows if r.get("error"))
    return result


# ---------------------------------------------------------------- running

def load_manifest(name):
    with open(os.path.join(DATA, name, "manifest.jsonl")) as f:
        return [json.loads(line) for line in f]


def wav_seconds(path):
    size = os.path.getsize(path)
    return max(0.0, (size - 44) / (16000 * 2))


def run_engine(engine, name):
    spec = ENGINES[engine]
    items = load_manifest(name)
    language = items[0]["language"]
    if language.split("-")[0] not in spec["langs"]:
        return None
    path = os.path.join(RAW, engine, f"{name}.jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    done = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                row = json.loads(line)
                done[row["audio"]] = row
    pending = [item for item in items if item["audio"] not in done]
    if pending:
        print(f"  {engine:15s} {name:16s} {len(pending)} clips", flush=True)
        if engine.startswith("apple"):
            apple_on_device_default(engine == "apple-ondevice")
        with open(path, "a") as f:
            for item in pending:
                wav = os.path.join(DATA, item["audio"])
                row = {"audio": item["audio"], "reference": item["reference"], "audio_seconds": wav_seconds(wav)}
                try:
                    row["hypothesis"], row["cold"], row["warm"] = spec["run"](wav, language)
                except Exception as error:  # keep going; failures are reported
                    row.update(hypothesis="", cold=0.0, warm=None, error=str(error))
                    print(f"    ! {item['audio']}: {error}", flush=True)
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
                f.flush()
                done[item["audio"]] = row
    return [done[item["audio"]] for item in items]


def report(summary):
    lines = ["# Speech-to-text evaluation", "",
             "Generated by `eval/run_eval.py`. Lower is better for every column.", ""]
    for name in SETS:
        if name not in summary:
            continue
        chinese = name.startswith("zh")
        meta = load_manifest(name)
        kind = meta[0]["kind"]
        lines += [f"## {name} ({len(meta)} clips, {kind} speech)", ""]
        if chinese:
            lines += ["| Engine | MER raw | MER script-norm. | Simplified outputs | Cold s/clip | Warm s/clip | Warm RTF |",
                      "|---|---|---|---|---|---|---|"]
        else:
            lines += ["| Engine | WER | Cold s/clip | Warm s/clip | Warm RTF |", "|---|---|---|---|---|"]
        for engine, s in sorted(summary[name].items(), key=lambda kv: kv[1]["norm" if chinese else "raw"]):
            warm = f"{s['warm_mean']:.2f}" if s["warm_mean"] is not None else "–"
            rtf = f"{s['warm_rtf']:.3f}" if s["warm_rtf"] is not None else "–"
            label = ENGINES[engine]["label"] + (f" ({s['failures']} failed)" if s["failures"] else "")
            if chinese:
                lines.append(f"| {label} | {s['raw']:.1%} | {s['norm']:.1%} | {s['simplified_share']:.0%} | {s['cold_mean']:.2f} | {warm} | {rtf} |")
            else:
                lines.append(f"| {label} | {s['raw']:.1%} | {s['cold_mean']:.2f} | {warm} | {rtf} |")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engines", default=",".join(ENGINES))
    parser.add_argument("--sets", default=",".join(SETS))
    args = parser.parse_args()
    engines = [e for e in args.engines.split(",") if e]
    sets = [s for s in args.sets.split(",") if s]

    summary_path = os.path.join(RESULTS, "summary.json")
    summary = json.load(open(summary_path)) if os.path.exists(summary_path) else {}
    try:
        for name in sets:
            for engine in engines:
                rows = run_engine(engine, name)
                if rows:
                    summary.setdefault(name, {})[engine] = score(rows, name.startswith("zh"))
    finally:
        if any(e.startswith("apple") for e in engines):
            apple_on_device_default(True)
    os.makedirs(RESULTS, exist_ok=True)
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    text = report(summary)
    with open(os.path.join(RESULTS, "report.md"), "w") as f:
        f.write(text + "\n")
    print(text)


if __name__ == "__main__":
    sys.exit(main())

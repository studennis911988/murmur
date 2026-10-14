#!/bin/bash
# Downloads local speech models into ~/Library/Application Support/Murmur/models
# and verifies their SHA-256. With --use, also switches Murmur to them.
#
#   scripts/setup-models.sh --use           Parakeet (English) + Breeze-ASR-25 (Mandarin, mixed)
#   scripts/setup-models.sh turbo --use     Whisper large-v3-turbo instead of Breeze
#   scripts/setup-models.sh parakeet        just download one model
#
# Models: parakeet (669 MB), breeze (1.7 GB), turbo (574 MB).
# Requires whisper.cpp for running them: brew install whisper-cpp
set -euo pipefail

DIR="$HOME/Library/Application Support/Murmur/models"
USE=0
WANTED=()
for arg in "$@"; do
  case "$arg" in
    --use) USE=1 ;;
    parakeet|breeze|turbo) WANTED+=("$arg") ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done
[ ${#WANTED[@]} -eq 0 ] && WANTED=(parakeet breeze)

model_info() {  # name -> "file url sha256"
  case "$1" in
    parakeet) echo "ggml-parakeet-tdt-0.6b-v3-q8_0.bin https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin 4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e" ;;
    breeze) echo "ggml-breeze-asr-25-q8_0.bin https://huggingface.co/alan314159/Breeze-ASR-25-whispercpp/resolve/main/ggml-model-q8_0.bin 669eb226a0e23b42465a6d2f60ce1902fbd534e19faab59511730420eb25e90d" ;;
    turbo) echo "ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2" ;;
  esac
}

mkdir -p "$DIR"
for name in "${WANTED[@]}"; do
  read -r file url sha <<<"$(model_info "$name")"
  target="$DIR/$file"
  if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sha" ]; then
    echo "✓ $file (already downloaded)"
    continue
  fi
  echo "↓ $file"
  curl -fL --retry 3 -C - -o "$target.part" "$url"
  if [ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" != "$sha" ]; then
    echo "✗ $file failed its checksum; deleted. Run the script again." >&2
    rm -f "$target.part"
    exit 1
  fi
  mv "$target.part" "$target"
  echo "✓ $file"
done

if ! command -v whisper-cli >/dev/null; then
  echo
  echo "Note: whisper.cpp isn't installed. Run: brew install whisper-cpp"
fi

[ "$USE" -eq 1 ] || { echo; echo "Choose them in Murmur → Settings → Transcription, or rerun with --use."; exit 0; }

# Murmur stores each setting as JSON data in its defaults domain.
set_default() {
  local json="\"${2//\"/\\\"}\""
  defaults write dev.murmur.app "$1" -data "$(printf '%s' "$json" | xxd -p | tr -d '\n')"
}
# The model for Auto/Chinese: the one asked for on this run, else what's on disk.
main=""
for name in "${WANTED[@]}" breeze turbo; do
  [ "$name" = parakeet ] && continue
  read -r file _ _ <<<"$(model_info "$name")"
  if [ -f "$DIR/$file" ]; then main="$DIR/$file"; break; fi
done
english=""
[ -f "$DIR/ggml-parakeet-tdt-0.6b-v3-q8_0.bin" ] && english="$DIR/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
[ -n "$main" ] || main="$english"
if [ -z "$main" ]; then
  echo "No model downloaded; nothing to configure." >&2
  exit 1
fi
set_default engine whisperCpp
set_default whisperModel "$main"
set_default englishModel "$english"
echo
echo "Murmur now uses: $(basename "$main") for Auto/Chinese${english:+, $(basename "$english") for English}."
if pgrep -x Murmur >/dev/null; then
  pkill -x Murmur
  sleep 1
  open -a Murmur
  echo "Restarted Murmur to apply the change."
fi

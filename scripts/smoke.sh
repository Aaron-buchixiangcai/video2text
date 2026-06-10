#!/usr/bin/env bash
# Repeatable end-to-end smoke test for the Video2Text pipeline.
#
# Defaults to the short YouTube sample already used during development.
# If the sample audio exists locally, this avoids network and only verifies
# decode -> Whisper -> optional diarization. Otherwise it exercises Downloader too.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${BIN:-.build/release/Video2Text}"
LANGUAGE="${SMOKE_LANGUAGE:-auto}"
SAMPLE_URL="${SAMPLE_URL:-https://www.youtube.com/watch?v=jNQXAC9IVRw}"
LOCAL_SAMPLE="${LOCAL_SAMPLE:-$HOME/Library/Application Support/Video2Text/downloads/smoke/jNQXAC9IVRw.m4a}"

if [ ! -x "$BIN" ]; then
  swift build -c release
fi

args=(--smoke --language "$LANGUAGE")

if [ "${SMOKE_DIARIZE:-0}" = "1" ]; then
  args+=(--diarize)
fi

if [ "${1:-}" != "" ]; then
  args+=("$@")
elif [ -f "$LOCAL_SAMPLE" ]; then
  args+=("$LOCAL_SAMPLE")
else
  args+=(--url "$SAMPLE_URL")
fi

"$BIN" "${args[@]}"

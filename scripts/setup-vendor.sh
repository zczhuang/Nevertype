#!/usr/bin/env bash
# Fetches the sherpa-onnx runtime that Package.swift links against into Vendor/ (git does not hold it).
#
# By default that is all it does: a build needs no speech model, and the app downloads its own from Settings. To also fetch
# the multilingual SenseVoice model (about 890 MB) into ~/Library/Application Support/Nevertype/Models, for testing other
# languages, run:  DOWNLOAD_SENSEVOICE=1 ./scripts/setup-vendor.sh
#
# Every archive is checked against its pinned SHA-256 before it is extracted. On a mismatch the download is moved to
# the Trash, nothing is extracted, and the script stops.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor"
MODEL_DIR="$HOME/Library/Application Support/Nevertype/Models"

SHERPA_NAME="sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/${SHERPA_NAME}.tar.bz2"
SHERPA_SHA256="f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417"   # 8,292,111 bytes

SENSEVOICE_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09"
SENSEVOICE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${SENSEVOICE_NAME}.tar.bz2"
SENSEVOICE_SHA256="bce28acdb0fb3a5b1e0b93f8b202e904ea1d2eca4f3a4c0cd5006626f10d540e"   # 886,547,748 bytes

# verify_sha256 <file> <expected sha256>
# Returns only when the file's SHA-256 equals the expected one. Otherwise the file is moved to the Trash and the whole
# script stops with status 1, before anything is extracted.
verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "==> [ERROR] SHA-256 mismatch for $(basename "$file")" >&2
        echo "    expected: $expected" >&2
        echo "    actual:   $actual" >&2
        /usr/bin/trash "$file" 2>/dev/null || true
        echo "    The download was discarded and nothing was extracted. Try again; if it keeps failing, please report an issue." >&2
        exit 1
    fi
    echo "==> SHA-256 OK: $(basename "$file")"
}

mkdir -p "$VENDOR_DIR"

if [ ! -d "$VENDOR_DIR/$SHERPA_NAME" ]; then
    echo "==> Downloading sherpa-onnx v1.13.8 arm64 shared C runtime..."
    curl -L --fail -o "$VENDOR_DIR/sherpa-lib.tar.bz2" "$SHERPA_URL"
    verify_sha256 "$VENDOR_DIR/sherpa-lib.tar.bz2" "$SHERPA_SHA256"
    tar -xjf "$VENDOR_DIR/sherpa-lib.tar.bz2" -C "$VENDOR_DIR/"
    /usr/bin/trash "$VENDOR_DIR/sherpa-lib.tar.bz2" 2>/dev/null || true
fi
echo "==> sherpa-onnx runtime ready."

if [ "${DOWNLOAD_SENSEVOICE:-0}" != "1" ]; then
    exit 0
fi

mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL_DIR/$SENSEVOICE_NAME/model.onnx" ]; then
    echo "==> DOWNLOAD_SENSEVOICE=1: downloading SenseVoice-Small FP32 (about 890 MB)..."
    curl -L --fail --retry 3 -o "$MODEL_DIR/sensevoice-fp32.tar.bz2" "$SENSEVOICE_URL"
    verify_sha256 "$MODEL_DIR/sensevoice-fp32.tar.bz2" "$SENSEVOICE_SHA256"
    tar -xjf "$MODEL_DIR/sensevoice-fp32.tar.bz2" -C "$MODEL_DIR/"
    /usr/bin/trash "$MODEL_DIR/sensevoice-fp32.tar.bz2" 2>/dev/null || true
fi

echo "==> SenseVoice-Small FP32 model ready."

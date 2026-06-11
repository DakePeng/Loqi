#!/bin/sh
# Fetches the prebuilt sherpa-onnx iOS frameworks (not committed — ~360MB).
# Run once after cloning, before `xcodegen generate`.
set -eu

VERSION="v1.13.2"
DEST="$(dirname "$0")/../ThirdParty/sherpa-onnx"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/sherpa-onnx-${VERSION}-ios-no-tts.tar.bz2"

if [ -d "$DEST/sherpa-onnx.xcframework" ] && [ -d "$DEST/onnxruntime.xcframework" ]; then
    echo "sherpa-onnx frameworks already present in $DEST"
    exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading sherpa-onnx ${VERSION} (~71MB)…"
curl -L -o "$TMP/ios.tar.bz2" "$URL"
tar xjf "$TMP/ios.tar.bz2" -C "$TMP"
cp -R "$TMP/build-ios-no-tts/sherpa-onnx.xcframework" "$DEST/"
cp -R "$TMP/build-ios-no-tts/ios-onnxruntime/1.17.1/onnxruntime.xcframework" "$DEST/"
echo "Installed into $DEST"

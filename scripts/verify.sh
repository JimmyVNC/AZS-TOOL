#!/bin/bash
set -euo pipefail

# Compiler checks do not launch the app, request TCC access, or change hardware.
AZS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AZS_ROOT"
AZS_DEVELOPER="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AZS_BIN="$AZS_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin"
AZS_SDK="${AZS_VERIFY_SDK:-$AZS_DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
AZS_ARCH="${AZS_VERIFY_ARCH:-$(uname -m)}"
AZS_MODE="${1:---typecheck}"
AZS_SOURCES=()
while IFS= read -r -d '' AZS_FILE; do AZS_SOURCES+=("$AZS_FILE"); done < <(rg --files -0 Sources/App -g '*.swift' -g '!AZSScrollToZoomEngine 2.swift')
AZS_FLAGS=(-swift-version 5 -target "$AZS_ARCH-apple-macosx14.0" -sdk "$AZS_SDK"
  -import-objc-header Sources/Support/mkey-Bridging-Header.h
  -I Sources/Engine -I Sources/Platform -I Sources/Platform/ScrollToZoom -module-name AZSTools)

if [[ "$AZS_MODE" == --typecheck ]]; then
  "$AZS_BIN/swiftc" -typecheck "${AZS_FLAGS[@]}" "${AZS_SOURCES[@]}"
  printf 'Full Swift typecheck passed (%s).\n' "$AZS_ARCH"
  exit 0
fi
AZS_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/azs-verify.XXXXXX")"
if [[ "$AZS_MODE" == --release ]]; then
  "$AZS_BIN/swiftc" -O -whole-module-optimization -emit-object "${AZS_FLAGS[@]}" "${AZS_SOURCES[@]}" -o "$AZS_OUTPUT/AZSTools.o"
  printf 'Release Swift compilation passed: %s\n' "$AZS_OUTPUT"
  exit 0
fi
if [[ "$AZS_MODE" != --tests ]]; then printf 'Use --typecheck, --release or --tests.\n' >&2; exit 2; fi

AZS_OBJECTS=()
while IFS= read -r -d '' AZS_FILE; do
  AZS_OBJECT="$AZS_OUTPUT/$(basename "$AZS_FILE").o"
  AZS_NATIVE_FLAGS=(-isysroot "$AZS_SDK" -target "$AZS_ARCH-apple-macosx14.0" -I Sources/Engine -I Sources/Platform -I Sources/Platform/ScrollToZoom)
  case "$AZS_FILE" in
    *.mm) "$AZS_BIN/clang++" -std=c++17 -fobjc-arc "${AZS_NATIVE_FLAGS[@]}" -c "$AZS_FILE" -o "$AZS_OBJECT" ;;
    *.cpp) "$AZS_BIN/clang++" -std=c++17 "${AZS_NATIVE_FLAGS[@]}" -c "$AZS_FILE" -o "$AZS_OBJECT" ;;
    *.m) "$AZS_BIN/clang" -fobjc-arc "${AZS_NATIVE_FLAGS[@]}" -c "$AZS_FILE" -o "$AZS_OBJECT" ;;
    *.c) "$AZS_BIN/clang" -std=gnu11 "${AZS_NATIVE_FLAGS[@]}" -c "$AZS_FILE" -o "$AZS_OBJECT" ;;
  esac
  AZS_OBJECTS+=("$AZS_OBJECT")
done < <(rg --files -0 Sources/Engine Sources/Platform -g '*.cpp' -g '*.mm' -g '*.m' -g '*.c' -g '!AZSSMCHelperMain.mm')
"$AZS_BIN/swiftc" -D AZS_TESTING "${AZS_FLAGS[@]}" "${AZS_SOURCES[@]}" Tests/OptimizationChecks.swift "${AZS_OBJECTS[@]}" \
  -F /System/Library/PrivateFrameworks -framework MultitouchSupport -framework CoreDisplay -framework Carbon \
  -framework Cocoa -framework IOKit -framework CoreVideo -framework CoreAudio -framework AudioToolbox -lc++ -o "$AZS_OUTPUT/OptimizationChecks"
"$AZS_OUTPUT/OptimizationChecks"
printf 'Verification artifacts: %s\n' "$AZS_OUTPUT"

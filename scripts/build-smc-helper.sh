#!/bin/sh
set -e

HELPER_DIR="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
mkdir -p "$HELPER_DIR"

xcrun clang++ -std=c++17 -O2 \
  -I"$SRCROOT/Sources/Platform" \
  "$SRCROOT/Sources/Platform/AZSSMC.mm" \
  "$SRCROOT/Sources/Platform/AZSSMCHelperMain.mm" \
  -framework IOKit \
  -o "$HELPER_DIR/azs-smc-helper"

chmod 755 "$HELPER_DIR/azs-smc-helper"

#!/bin/sh
set -e

HELPER_DIR="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
mkdir -p "$HELPER_DIR"

AZS_HELPER_ARCH_FLAGS=""
for AZS_HELPER_ARCH in $ARCHS; do
  AZS_HELPER_ARCH_FLAGS="$AZS_HELPER_ARCH_FLAGS -arch $AZS_HELPER_ARCH"
done

xcrun clang++ -std=c++17 -O2 $AZS_HELPER_ARCH_FLAGS \
  -I"$SRCROOT/Sources/Platform" \
  "$SRCROOT/Sources/Platform/AZSSMC.mm" \
  "$SRCROOT/Sources/Platform/AZSSMCHelperMain.mm" \
  -framework IOKit \
  -o "$HELPER_DIR/azs-smc-helper"

chmod 755 "$HELPER_DIR/azs-smc-helper"

# A nested executable must be signed before Xcode seals the outer app bundle.
# Otherwise a normal Release build fails at the final CodeSign phase even when
# the app uses the project's ad-hoc "Sign to Run Locally" identity.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ]; then
  # Desktop/iCloud-backed build folders can attach FinderInfo/provenance xattrs
  # to freshly created products; codesign rejects those as resource-fork data.
  /usr/bin/xattr -cr "$TARGET_BUILD_DIR/$WRAPPER_NAME"
  AZS_HELPER_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "$AZS_HELPER_SIGN_IDENTITY" \
    "$HELPER_DIR/azs-smc-helper"
fi

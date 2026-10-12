#!/usr/bin/env bash
set -euo pipefail
if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] || [ "$EXPANDED_CODE_SIGN_IDENTITY" = "-" ]; then
  echo "Credential persistence requires a signing certificate. Run ./script/setup_local_signing.sh and use HermesMac Local Development." >&2
  exit 1
fi
helper_destination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/HermesCredentialHelper"
helper_build="$DERIVED_FILE_DIR/HermesCredentialHelper"
mkdir -p "$(dirname "$helper_destination")" "$helper_build"
helper_archives=()
for helper_arch in $ARCHS; do
  helper_binary="$helper_build/$helper_arch"
  /usr/bin/xcrun swiftc -O -D KEYCHAIN_HELPER -target "$helper_arch-apple-macosx14.0" \
    -sdk "$SDKROOT" "$SRCROOT/HermesMac/Services/Keychain.swift" \
    "$SRCROOT/Tools/CredentialHelper/main.swift" -o "$helper_binary"
  helper_archives+=("$helper_binary")
done
/usr/bin/xcrun lipo -create "${helper_archives[@]}" -output "$helper_destination"
/usr/bin/codesign --force --timestamp=none --options runtime \
  --identifier com.hermes.mac.credentials-helper \
  --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helper_destination"

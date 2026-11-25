#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# APP_NAME, VERSION (and BUNDLE_ID, PRODUCT_NAME) come from AppBrand.swift.
source "$ROOT_DIR/scripts/brand.sh"

DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macOS-arm64.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-NevertypeNotary}"

echo "==> 1. Building & signing ${APP_NAME}.app v${VERSION}..."
"$ROOT_DIR/scripts/build-app.sh"
"$ROOT_DIR/build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" --self-test

mkdir -p "$DIST_DIR"
STAGE_DIR="$(mktemp -d -t nevertype_dmg_stage)"
trap '/usr/bin/trash "$STAGE_DIR" 2>/dev/null || true' EXIT

ditto "$ROOT_DIR/build/${APP_NAME}.app" "$STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/Install ${APP_NAME}.txt" <<EOF
${APP_NAME} quick install guide
==============================

1. Drag "${APP_NAME}.app" onto the "Applications" folder next to it.
2. Open ${APP_NAME}. If macOS blocks the first launch, open System Settings > Privacy & Security, scroll to the bottom and click
   "Open Anyway" once, or run this in Terminal: xattr -cr /Applications/${APP_NAME}.app
3. Follow the three setup steps: allow the microphone and Accessibility, download an on-device speech model (or paste your own
   API keys), and pick the shortcut. Then press it in any text field and talk.
EOF

if [ -f "$DMG_PATH" ]; then
    /usr/bin/trash "$DMG_PATH" 2>/dev/null || true
fi

echo "==> 2. Packaging compressed UDZO installer DMG..."
hdiutil create \
    -volname "${APP_NAME} v${VERSION}" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

SIGN_HASH="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application:/ {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
    codesign --force --timestamp --sign "$SIGN_HASH" "$DMG_PATH"
    echo "==> 3. Signed DMG with Developer ID certificate ($SIGN_HASH)"
fi

# Automatic Apple Cloud Notarization + Stapling (fail-fast unless ALLOW_UNNOTARIZED=1 for local test builds)
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> 4. Submitting DMG to Apple Notary Service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    echo "==> 5. Notarization & ticket stapling complete! Zero Gatekeeper warnings on any Mac."
elif [ "${ALLOW_UNNOTARIZED:-0}" = "1" ]; then
    echo "==> [Warn] ALLOW_UNNOTARIZED=1 set; skipping Apple Notarization for local test build."
else
    echo "==> [ERROR] Apple Notarization profile '$NOTARY_PROFILE' not found. Refusing to ship unnotarized DMG!" >&2
    echo "    Set ALLOW_UNNOTARIZED=1 only for local test builds." >&2
    exit 1
fi

ls -lh "$DMG_PATH"

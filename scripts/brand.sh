#!/usr/bin/env bash
# Sourced by build-app.sh and package-dmg.sh. Reads the app's name, bundle identifier and version from
# Sources/TypeZero/Core/AppBrand.swift, the single source of truth, so the app bundle can never disagree with the code.
#
# Sets:
#   PRODUCT_NAME  the SwiftPM product (Package.swift), which is also the module name: "TypeZero"
#   APP_NAME      what users see and what the .app and its executable are called
#   BUNDLE_ID     CFBundleIdentifier (also the Keychain service name)
#   VERSION       CFBundleShortVersionString
#
# Needs ROOT_DIR to be set by the caller.

PRODUCT_NAME="TypeZero"
BRAND_FILE="$ROOT_DIR/Sources/TypeZero/Core/AppBrand.swift"

# brand_value <key>: the string literal assigned to `public static let <key> = "..."` in AppBrand.swift.
brand_value() {
    sed -n "s/^[[:space:]]*public static let $1 = \"\\(.*\\)\"[[:space:]]*\$/\\1/p" "$BRAND_FILE" | head -1
}

APP_NAME="$(brand_value name)"
BUNDLE_ID="$(brand_value bundleID)"
VERSION="$(brand_value version)"

if [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ] || [ -z "$VERSION" ]; then
    echo "==> [ERROR] could not read name, bundleID and version from $BRAND_FILE" >&2
    exit 1
fi

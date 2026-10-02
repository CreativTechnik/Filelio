#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
PKG="$PROJECT_DIR/dist/Filelio-$VERSION.pkg"
DMG="$PROJECT_DIR/dist/Filelio-$VERSION.dmg"

: "${NOTARYTOOL_PROFILE:?NOTARYTOOL_PROFILE muss auf ein gespeichertes notarytool-Keychain-Profil zeigen.}"

if [ ! -f "$PKG" ] || [ ! -f "$DMG" ]; then
	echo "PKG oder DMG fehlt. Zuerst beide Distributionsdateien bauen." >&2
	exit 1
fi

xcrun notarytool submit "$PKG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

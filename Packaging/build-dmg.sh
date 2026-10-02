#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$PROJECT_DIR/build/Filelio.app"
DIST="$PROJECT_DIR/dist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
DMG="$DIST/Filelio-$VERSION.dmg"
STAGING=$(/usr/bin/mktemp -d "/tmp/Filelio-DMG.XXXXXX")
SIGN_IDENTITY=${DMG_SIGN_IDENTITY:-${APPLICATION_SIGN_IDENTITY:--}}

cleanup() {
	case "$STAGING" in
		/tmp/Filelio-DMG.*) /bin/rm -rf "$STAGING" ;;
	esac
}
trap cleanup EXIT INT TERM

if [ ! -d "$APP" ]; then
	"$PROJECT_DIR/Packaging/build.sh"
fi

/bin/mkdir -p "$DIST"
/usr/bin/ditto --norsrc "$APP" "$STAGING/Filelio.app"
/bin/ln -s /Applications "$STAGING/Programme"
/bin/cp "$PROJECT_DIR/Packaging/DMG-LIESMICH.txt" "$STAGING/LIESMICH.txt"

/usr/bin/hdiutil create \
	-volname "Filelio" \
	-srcfolder "$STAGING" \
	-ov \
	-format UDZO \
	-fs HFS+ \
	"$DMG"

/usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$DMG"
/usr/bin/codesign --verify --verbose=2 "$DMG"
/usr/bin/hdiutil verify "$DMG"
echo "DMG fertig: $DMG"

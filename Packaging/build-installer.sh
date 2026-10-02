#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$PROJECT_DIR/build/Filelio.app"
DIST="$PROJECT_DIR/dist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
PACKAGE="$DIST/Filelio-$VERSION.pkg"

if [ ! -d "$APP" ]; then
	"$PROJECT_DIR/Packaging/build.sh"
fi

/bin/mkdir -p "$DIST"

if [ -n "${INSTALLER_SIGN_IDENTITY:-}" ]; then
	COPYFILE_DISABLE=1 /usr/bin/pkgbuild \
		--component "$APP" \
		--install-location /Applications \
		--identifier de.creativtechnik.Filelio.installer \
		--version "$VERSION" \
		--sign "$INSTALLER_SIGN_IDENTITY" \
		"$PACKAGE"
else
	COPYFILE_DISABLE=1 /usr/bin/pkgbuild \
		--component "$APP" \
		--install-location /Applications \
		--identifier de.creativtechnik.Filelio.installer \
		--version "$VERSION" \
		"$PACKAGE"
fi

/usr/sbin/pkgutil --check-signature "$PACKAGE" || true
echo "Installer fertig: $PACKAGE"

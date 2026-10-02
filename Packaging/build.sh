#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/Filelio.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PLUGINS="$CONTENTS/PlugIns"
FINDER_APP_EXTENSION="$PLUGINS/Filelio Finder.appex"
FINDER_CONTENTS="$FINDER_APP_EXTENSION/Contents"
FINDER_MACOS="$FINDER_CONTENTS/MacOS"
FINDER_RESOURCES="$FINDER_CONTENTS/Resources"
SOURCE_FILES="$PROJECT_DIR/Sources/Core.swift $PROJECT_DIR/Sources/DirectoryMonitor.swift $PROJECT_DIR/Sources/StructureEditor.swift $PROJECT_DIR/Sources/RenameUI.swift $PROJECT_DIR/Sources/FinderToolkit.swift $PROJECT_DIR/Sources/FinderToolsUI.swift $PROJECT_DIR/Sources/App.swift"
SIGN_IDENTITY=${APPLICATION_SIGN_IDENTITY:--}

/bin/rm -rf "$APP"
/bin/mkdir -p "$MACOS" "$RESOURCES" "$FINDER_MACOS" "$FINDER_RESOURCES"

xcrun swiftc -swift-version 5 -parse-as-library -O \
	-target arm64-apple-macos13.0 \
	-framework AppKit -framework ServiceManagement -framework CoreServices -framework PDFKit -framework FinderSync \
	$SOURCE_FILES \
	-o "$BUILD_DIR/Filelio-arm64"

xcrun swiftc -swift-version 5 -parse-as-library -O \
	-target x86_64-apple-macos13.0 \
	-framework AppKit -framework ServiceManagement -framework CoreServices -framework PDFKit -framework FinderSync \
	$SOURCE_FILES \
	-o "$BUILD_DIR/Filelio-x86_64"

xcrun swiftc -swift-version 5 -parse-as-library -O \
	-module-name FilelioFinderSync \
	-target arm64-apple-macos13.0 \
	-framework AppKit -framework FinderSync \
	-Xlinker -e -Xlinker _NSExtensionMain \
	"$PROJECT_DIR/Sources/FinderSyncExtension.swift" \
	-o "$BUILD_DIR/FilelioFinderSync-arm64"

xcrun swiftc -swift-version 5 -parse-as-library -O \
	-module-name FilelioFinderSync \
	-target x86_64-apple-macos13.0 \
	-framework AppKit -framework FinderSync \
	-Xlinker -e -Xlinker _NSExtensionMain \
	"$PROJECT_DIR/Sources/FinderSyncExtension.swift" \
	-o "$BUILD_DIR/FilelioFinderSync-x86_64"

/usr/bin/lipo -create \
	"$BUILD_DIR/Filelio-arm64" \
	"$BUILD_DIR/Filelio-x86_64" \
	-output "$MACOS/Filelio"

/usr/bin/lipo -create \
	"$BUILD_DIR/FilelioFinderSync-arm64" \
	"$BUILD_DIR/FilelioFinderSync-x86_64" \
	-output "$FINDER_MACOS/FilelioFinderSync"

/bin/chmod 755 "$MACOS/Filelio"
/bin/chmod 755 "$FINDER_MACOS/FilelioFinderSync"
/bin/cp -p "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
/bin/cp -p "$PROJECT_DIR/Resources/FinderSync-Info.plist" "$FINDER_CONTENTS/Info.plist"
/bin/cp -p "$PROJECT_DIR/Resources/MenuBarIcon.png" "$FINDER_RESOURCES/MenuBarIcon.png"
/bin/cp -p "$PROJECT_DIR/Resources/Filelio.icns" "$RESOURCES/Filelio.icns"
/bin/cp -p "$PROJECT_DIR/Resources/AppIcon-master.png" "$RESOURCES/AppIcon-master.png"
/bin/cp -p "$PROJECT_DIR/Resources/MenuBarIcon.png" "$RESOURCES/MenuBarIcon.png"
/usr/bin/printf 'APPL????' > "$CONTENTS/PkgInfo"
/usr/bin/xattr -cr "$APP"

/usr/bin/codesign --force --options runtime \
	--entitlements "$PROJECT_DIR/Resources/FinderSync.entitlements" \
	--sign "$SIGN_IDENTITY" "$FINDER_APP_EXTENSION"

/usr/bin/codesign --force --options runtime \
	--entitlements "$PROJECT_DIR/Resources/Filelio.entitlements" \
	--sign "$SIGN_IDENTITY" "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$FINDER_APP_EXTENSION"
/usr/bin/lipo -info "$MACOS/Filelio"
/usr/bin/lipo -info "$FINDER_MACOS/FilelioFinderSync"
/usr/bin/plutil -lint "$CONTENTS/Info.plist"
/usr/bin/plutil -lint "$FINDER_CONTENTS/Info.plist"

echo "Build fertig: $APP"

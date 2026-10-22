#!/bin/zsh
# Builds Vitals.app (menu bar app) into ./build
set -e
cd "$(dirname "$0")"
swift build -c release -Xswiftc -Osize -Xswiftc -enforce-exclusivity=unchecked -Xlinker -dead_strip
strip -x .build/release/Vitals
APP=build/Vitals.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Vitals $APP/Contents/MacOS/Vitals

ICONSET=$(mktemp -d)/Vitals.iconset && mkdir -p $ICONSET
swift Scripts/make_icon.swift $ICONSET/base.png
for s in 16 32 128 256 512; do
  sips -z $s $s $ICONSET/base.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $ICONSET/base.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
rm $ICONSET/base.png
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Vitals</string>
<key>CFBundleDisplayName</key><string>Vitals</string>
<key>CFBundleIdentifier</key><string>com.alexgracas.vitals</string>
<key>CFBundleExecutable</key><string>Vitals</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Ler a bateria de teclados e mouses Bluetooth já conectados.</string>
<key>NSDesktopFolderUsageDescription</key><string>Medir o espaço ocupado pela Mesa.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Medir o espaço ocupado por Documentos.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Medir o espaço ocupado por Downloads.</string>
</dict></plist>
PL
# A stable identity keeps macOS privacy permissions (folders, Bluetooth) across rebuilds; an ad-hoc
# signature changes with every build, so macOS would ask again each time. Override with SIGN_IDENTITY.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" $APP
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "OK: $APP"

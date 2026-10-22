#!/bin/zsh
# Builds Vitals.app and wraps it in an installer package (.pkg) and a disk image (.dmg) in ./dist
set -e
cd "$(dirname "$0")/.."
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Vitals.app/Contents/Info.plist)
rm -rf dist && mkdir -p dist
TMP=$(mktemp -d)

# .pkg: installs Vitals.app into /Applications (not relocatable, so it never "updates" a copy elsewhere)
mkdir -p $TMP/root/Applications && cp -R build/Vitals.app $TMP/root/Applications/
pkgbuild --analyze --root $TMP/root $TMP/component.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO $TMP/component.plist
pkgbuild --root $TMP/root --component-plist $TMP/component.plist --identifier com.alexgracas.vitals \
  --version $VERSION --install-location / dist/Vitals-$VERSION.pkg >/dev/null

# .dmg: drag-and-drop to Applications
mkdir -p $TMP/dmg && cp -R build/Vitals.app $TMP/dmg/ && ln -s /Applications $TMP/dmg/Applications
hdiutil create -volname "Vitals $VERSION" -srcfolder $TMP/dmg -ov -format UDZO dist/Vitals-$VERSION.dmg >/dev/null

rm -rf $TMP
shasum -a 256 dist/*

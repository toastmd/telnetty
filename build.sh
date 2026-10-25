#!/bin/bash
# Builds Telnetty.app (Apple silicon + Intel), the installer Telnetty-<version>.pkg and the disk image Telnetty-<version>.dmg.
# Needs a Mac with the command line tools:  xcode-select --install
# Optional signing:  DEV_ID_APP="Developer ID Application: Name (TEAMID)"  DEV_ID_INSTALLER="Developer ID Installer: Name (TEAMID)" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
VERSION="1.0.0"
[ "$(uname)" = "Darwin" ] || { echo "Telnetty has to be built on macOS."; exit 1; }
command -v swiftc >/dev/null || { echo "The Swift compiler is missing. Run: xcode-select --install"; exit 1; }

rm -rf build
APP="build/Telnetty.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/dmg

echo "==> Compiling"
BUILT=()
for ARCH in arm64 x86_64; do
  if swiftc -O -target "$ARCH-apple-macos11.0" -o "build/Telnetty-$ARCH" Sources/*.swift -framework Cocoa -framework Network; then
    BUILT+=("build/Telnetty-$ARCH")
  else
    echo "   (could not build for $ARCH, continuing)"
  fi
done
[ "${#BUILT[@]}" -gt 0 ] || { echo "Compilation failed."; exit 1; }
lipo -create "${BUILT[@]}" -output "$APP/Contents/MacOS/Telnetty"
rm -f build/Telnetty-arm64 build/Telnetty-x86_64

echo "==> Bundle and icon"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
ICONSET="build/Telnetty.iconset"
mkdir -p "$ICONSET"
for S in 16 32 128 256 512; do
  sips -z $S $S Resources/Telnetty-icon.png --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
  D=$((S * 2))
  sips -z $D $D Resources/Telnetty-icon.png --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Telnetty.icns"

echo "==> Signing"
if [ -n "${DEV_ID_APP:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$APP"
else
  codesign --force --sign - "$APP"   # ad-hoc: runs on this Mac and, with a right-click, on others
fi

echo "==> Installer package"
pkgbuild --component "$APP" --install-location /Applications --identifier com.toastmd.telnetty --version "$VERSION" build/Telnetty-component.pkg
SIGN=()
[ -n "${DEV_ID_INSTALLER:-}" ] && SIGN=(--sign "$DEV_ID_INSTALLER")
productbuild --distribution Resources/distribution.xml --resources Resources/installer --package-path build ${SIGN[@]+"${SIGN[@]}"} "build/Telnetty-$VERSION.pkg"
rm -f build/Telnetty-component.pkg

echo "==> Disk image"
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Telnetty" -srcfolder build/dmg -ov -format UDZO "build/Telnetty-$VERSION.dmg" >/dev/null
rm -rf build/dmg build/Telnetty.iconset

echo
echo "Done:"
echo "   build/Telnetty.app"
echo "   build/Telnetty-$VERSION.pkg   (double-click to install)"
echo "   build/Telnetty-$VERSION.dmg   (drag Telnetty to Applications)"

#!/bin/bash
# Compila "Tapa Cerrada.app" (universal: Apple Silicon + Intel) en build/.
# Uso: scripts/build-app.sh [versión]      Requiere Xcode o las Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"
OUT="build"
APP="$OUT/Tapa Cerrada.app"
MIN_MACOS="14.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$OUT/obj"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

for ARCH in arm64 x86_64; do
  echo "== Compilando $ARCH"
  xcrun swiftc -swift-version 5 -parse-as-library -O \
    -target "$ARCH-apple-macos$MIN_MACOS" -sdk "$SDK" \
    -module-name TapaCerrada Sources/*.swift -o "$OUT/obj/TapaCerrada-$ARCH"
done
lipo -create "$OUT/obj/TapaCerrada-arm64" "$OUT/obj/TapaCerrada-x86_64" -output "$APP/Contents/MacOS/TapaCerrada"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/com.alejandro.tapacerrada.agent.plist "$APP/Contents/Library/LaunchAgents/"

if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
fi
if [ -n "${TC_PROJECT_URL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :TCProjectURL $TC_PROJECT_URL" "$APP/Contents/Info.plist"
fi

# Firma ad-hoc (sin cuenta de desarrollador de Apple).
codesign --force --deep --sign - "$APP"
echo "== OK: $APP"

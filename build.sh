#!/bin/bash
# Compile Fouine et assemble build/Fouine.app (Sparkle et traductions inclus).
# Signature : IDENTITE="Nom du certificat" ./build.sh, sinon le premier certificat
# de signature trouvé, sinon signature ad hoc (l'accès complet au disque sera alors
# à réaccorder après chaque recompilation).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Fouine.app"
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$(swift build -c release --show-bin-path)/Fouine" "$APP/Contents/MacOS/Fouine"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/*.png "$APP/Contents/Resources/"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

IDENTITE="${IDENTITE:-$(security find-identity -v -p codesigning | awk 'NR==1 && /^ *1\)/ {print $2}')}"
IDENTITE="${IDENTITE:--}"
# Sparkle se signe de l'intérieur vers l'extérieur, puis l'app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for piece in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc \
             Versions/B/Autoupdate Versions/B/Updater.app; do
    codesign --force --sign "$IDENTITE" "$FW/$piece"
done
codesign --force --sign "$IDENTITE" "$FW"
codesign --force --sign "$IDENTITE" "$APP"

echo "OK : $APP"

#!/bin/bash
# Régénère Resources/AppIcon.icns à partir de outils/icone.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift outils/icone.swift "$TMP/1024.png"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for taille in 16 32 128 256 512; do
    sips -z $taille $taille "$TMP/1024.png" --out "$SET/icon_${taille}x${taille}.png" >/dev/null
    double=$((taille * 2))
    sips -z $double $double "$TMP/1024.png" --out "$SET/icon_${taille}x${taille}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "OK : Resources/AppIcon.icns"

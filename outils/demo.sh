#!/bin/bash
# Données de démonstration pour les captures d'écran du README : un projet inventé,
# « Wrenfield », dans /Users/Shared. Aucun fichier personnel n'apparaît dans les captures.
#   ./outils/demo.sh          crée le dossier
#   ./outils/demo.sh remove   le supprime
# Lancer ensuite l'app avec, par exemple :
#   open build/Fouine.app --args -demoScope /Users/Shared/Wrenfield -demoQuery wrenfield
set -euo pipefail
D="/Users/Shared/Wrenfield"
if [ "${1:-}" = "remove" ]; then rm -rf "$D"; echo "Removed $D"; exit 0; fi
[ -e "$D" ] && { echo "$D already exists"; exit 1; }

mkdir -p "$D"/{"Wrenfield Design","Wrenfield Reports/2026","wrenfield-app/Sources",Archive}
blob() { head -c "$2" /dev/zero > "$D/$1"; }      # fichier de la taille voulue
text() { printf '%s\n' "$2" > "$D/$1"; }           # fichier texte, pour la recherche de contenu

blob "Wrenfield roadmap.pdf" 860000
blob "Wrenfield budget 2026.xlsx" 98000
blob "Wrenfield Reports/2026/Wrenfield Q1 report.pdf" 2100000
blob "Wrenfield Reports/2026/Wrenfield Q2 report.pdf" 2400000
blob "Wrenfield Reports/Wrenfield annual summary.docx" 317000
blob "Wrenfield Design/wrenfield-logo.png" 184000
blob "Wrenfield Design/wrenfield-logo@2x.png" 532000
blob "Wrenfield Design/Wrenfield icon set.sketch" 6300000
blob "Wrenfield Design/wrenfield-wordmark.svg" 12000
blob "Wrenfield Design/Wrenfield launch video.mov" 155200000
blob "Archive/wrenfield-backup-2025.zip" 325100000
blob "Wrenfield press kit.zip" 25200000
blob "wrenfield-release-1.4.dmg" 64000000
blob ".wrenfield-cache" 45000

text "Wrenfield meeting notes.md" "# Wrenfield weekly sync
- Quarterly revenue is up 12 % on the previous quarter.
- The launch video ships with the press kit on Monday.
- Sync engine: migrate the store before the 1.5 release."
text "Archive/Wrenfield old notes.txt" "Quarterly revenue targets for 2025 were missed in Q3.
Keep the backup archive until the audit is over."
text "wrenfield-app/README-wrenfield.md" "# Wrenfield app
Build with the sync engine enabled. Quarterly revenue dashboards live in the Reports module."
text "wrenfield-app/wrenfield.config.json" '{ "syncEngine": true, "reports": { "quarterlyRevenue": true } }'
text "wrenfield-app/Sources/WrenfieldApp.swift" "// Entry point of the Wrenfield app.
struct WrenfieldApp { let syncEngine = WrenfieldStore() }"
text "wrenfield-app/Sources/WrenfieldStore.swift" "// Local store used by the sync engine.
final class WrenfieldStore { var quarterlyRevenue: Double = 0 }"

touch -t 202611140930 "$D/Wrenfield roadmap.pdf"
touch -t 202610021410 "$D/Wrenfield budget 2026.xlsx"
touch -t 202604031100 "$D/Wrenfield Reports/2026/Wrenfield Q1 report.pdf"
touch -t 202607021100 "$D/Wrenfield Reports/2026/Wrenfield Q2 report.pdf"
touch -t 202512181700 "$D/Archive/wrenfield-backup-2025.zip"
touch -t 202611091205 "$D/Wrenfield Design/Wrenfield launch video.mov"
touch -t 202609151000 "$D/wrenfield-release-1.4.dmg"
touch -t 202508200915 "$D/Archive/Wrenfield old notes.txt"
echo "Created $D"

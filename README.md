# Fouine

**Three letters in, every match on every disk.** Fouine keeps an index of all your volumes, so a
file name search answers while you are still typing: about 96,000 matches out of 6.3 million items
in a fifth of a second. Hidden files, system folders and external drives included.

It is a native macOS file finder in the spirit of EasyFind, with the one thing EasyFind lacks: it
doesn't walk the disk on every search. *Fouine* is French for a stone marten, and for someone who
pokes their nose everywhere.

- **Instant name search** over the whole machine, ignoring case and accents
- **Always current**: the index follows every change live, and catches up on what happened while
  the app was closed
- **Content search** on demand, reading the files in parallel
- **EasyFind-style criteria**: files or folders, all words / any word / exact phrase / wildcards /
  regular expressions, plus filters by kind, date and size
- **Every result**, not the first few thousand: the list stays smooth with hundreds of thousands
  of rows
- **Truly native**: Swift and SwiftUI, a 2 MB download, no Electron

### Support the project
Free and open-source 🙂 — if you feel like it, buy me a few tokens:

[![Buy me tokens](docs/buy-me-tokens.png)](https://paypal.me/lbenh)

**Contents:** [Searching](#searching) · [The index](#the-index) · [Results](#results) ·
[Keyboard](#keyboard) · [macOS integration](#macos-integration) · [Install](#install) ·
[Build](#build-from-source) · [Releasing](#releasing) · [Known limits](#known-limits) ·
[Project layout](#project-layout)

## Searching

### Names

- Results appear **as you type**, from the first character
- Matching ignores **case and accents**: `resume` finds `Résumé.pdf`
- **Operators**: all words, any word, exact phrase, wildcards (`*` and `?`, matched against the
  whole name) and regular expressions
- **Search for** files and folders, only files, or only folders
- The matched terms are **highlighted** in each name

### Contents

- Switch to **Contents**, type the text and press Return
- Only the files in the chosen location and matching the filters are read, several at a time
- Optional **Match case**
- Cloud files that aren't downloaded are skipped, so a search never triggers a download
- A search can be stopped at any moment; what was found stays in the list

### Location

- **All volumes**, any single mounted volume, your home folder, or a folder you pick
- Choosing the startup volume leaves the external drives out

### Filters

- **Kind**: images, audio, video, documents, archives, code, applications
- **Date modified**: today, last 7 days, last 30 days, last 12 months
- **Size**: larger than 1 MB, 100 MB or 1 GB
- **Package contents**: look inside `.app`, `.framework`, `.photoslibrary` and similar bundles,
  off by default as in the Finder
- **Invisible files and folders**, on by default
- **Caches and technical folders**, off by default: the contents of caches, `node_modules`,
  `.git`, build folders and the volumes' own Spotlight stores are left out of the index. The
  folders themselves are still found. They churn constantly and were most of the background
  work; ticking the box rebuilds the index with them

## The index

Measured on a Mac with 6.3 million indexed items across an internal SSD, two external SSDs and a 24 TB
RAID:

| | |
| --- | --- |
| First full index | 50 s |
| Refresh (⌘R) | 7.6 s |
| Index size on disk | about 760 MB |
| CPU at rest, on a busy machine | under 1 % |
| Memory at rest | about 95 MB |
| `sylenth1`, 95,756 matches | 0.14 s to query, 0.06 s to sort |

- **Live updates**: macOS reports every file created, deleted, renamed or modified, and only those
  entries are touched. Changes are applied in 3-second batches, which keeps the CPU near idle even
  while caches and build folders churn
- **Catch-up at launch**: the changes made while Fouine was closed are replayed from the system's
  own history. If part of that history is gone, a refresh catches up instead of a full rebuild
- **Refresh** only re-reads the folders whose modification date changed, and the search stays
  usable meanwhile
- **Rebuild the whole index** stays available in the Fouine menu, as a fallback
- Each volume is read by its own pool of 8 threads: more than that and the reads get in each
  other's way in the kernel, and a slow disk would otherwise hold back the fast ones
- The status bar shows the number of items and the size of the index

The index lives in `~/Library/Application Support/Fouine/index.sqlite`: an SQLite database with
an FTS5 trigram index over the names.

Not indexed: `/System/Volumes` (a duplicate of the data volume), `/dev`, Time Machine snapshots
and network volumes. Unless **Caches and technical folders** is ticked, the system's temporary
folders (`/private/tmp`, `/private/var/folders`) are left out too.

## Results

- Sortable columns: name, date modified, size, kind, location. Their widths are remembered
- **Folders first**, so files and folders aren't mixed. It can be turned off
- **Toolbar and right-click**: Open, Show in Finder, Quick Look, Copy Path, Move to Trash (asks
  first)
- The **path bar** at the bottom shows where the selected item lives

## Keyboard

| | |
| --- | --- |
| Return, in the search field | Search now (needed for contents) |
| Return, on a result | Open |
| Space, on a result | Quick Look |
| ⌘R | Refresh the index |
| ⌘+ / ⌘- / ⌘0 | Zoom in, zoom out, actual size |

## macOS integration

- **Follows the system language**: English and French
- **Menu bar icon**: open the window, refresh the index, check for updates, quit. The app keeps
  running, and the index stays current, with the window closed
- **Zoom** from 70 % to 200 %, remembered between launches
- The **window** comes back at the size and place you left it
- **Updates itself** through [Sparkle](https://sparkle-project.org): new versions are downloaded
  from this repository's releases and checked against an EdDSA signature before they are installed

## Install

1. Download `Fouine-x.y.z.zip` from the [latest release](https://github.com/blckdvc/Fouine/releases/latest)
   and unzip it.
2. Move `Fouine.app` to `/Applications`.
3. The app isn't notarized by Apple. On first launch macOS refuses to open it: right-click the
   app, choose Open, then confirm. Or clear the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Fouine.app
   ```

4. Grant **Full Disk Access** when the app asks: System Settings › Privacy & Security › Full Disk
   Access. Without it macOS hides most of the disk, and asks for each protected folder in turn.

Requires macOS 14 or later.

## Build from source

Xcode's command-line tools are enough; there is no Xcode project.

```bash
./build.sh
```

```bash
open build/Fouine.app
```

`build.sh` compiles with Swift Package Manager, assembles `build/Fouine.app` (binary, `Info.plist`,
translations, icon, Sparkle) and signs it with the first code-signing certificate it finds. A
stable signature matters: with an ad hoc one, Full Disk Access has to be granted again after every
build. To pick the certificate:

```bash
IDENTITE="Developer ID Application: Your Name" ./build.sh
```

The icon is drawn by a script. To change it, edit `outils/icone.swift`, then:

```bash
./outils/icone.sh
```

## Releasing

```bash
./release.sh 0.2.0
```

It sets the version, builds, zips the app, signs the archive with the Sparkle key from the
keychain, writes `appcast.xml`, tags, pushes and creates the GitHub release. Installed copies then
find the new version by themselves. The private key never leaves the keychain: without it, no
update can be published for the copies already out there.

## Known limits

- Content search ignores case for unaccented letters only, and has no index: across a whole disk
  it takes as long as reading the files takes
- Wildcards and regular expressions apply to names, not to contents
- A one- or two-letter term matches most of the disk, so it stops at 100,000 results. Everything
  else stops at 2 million
- Refresh sees additions, removals and renames. A change inside a file (size, date) is picked up
  by the live updates, not by a refresh
- The filter pop-ups, the column headers and the toolbar don't follow the zoom
- Not notarized, and there is no license file yet

## Project layout

| File | Role |
| --- | --- |
| `Sources/Fouine/Database.swift` | SQLite connection and schema |
| `Sources/Fouine/IndexStore.swift` | Writes to the index |
| `Sources/Fouine/FastScanner.swift` | Parallel walk of the disk |
| `Sources/Fouine/IndexService.swift` | Full index, refresh, and applying file-system events |
| `Sources/Fouine/Watcher.swift` | FSEvents stream |
| `Sources/Fouine/Noise.swift` | Which folders count as caches and technical folders |
| `Sources/Fouine/SearchEngine.swift` | Name and content search |
| `Sources/Fouine/SearchModel.swift`, `ContentView.swift` | The SwiftUI interface |
| `Sources/Fouine/ResultsTable.swift` | Native results table |
| `Sources/Fouine/FouineApp.swift` | Window, menus, About, menu bar, Sparkle |
| `Sources/Fouine/Localisation.swift` | Text in the system language |
| `Resources/` | `Info.plist`, translations, icon |
| `outils/` | The icon's drawing script |

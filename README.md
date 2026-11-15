# TimeFinder

A Finder-style browser for Time Machine backups of *other* Macs — for example a `.sparsebundle`
on a NAS or SMB share — so you can look around, preview, and restore files without the
Time Machine UI and without restoring a whole machine.

<!-- Screenshot: add docs/screenshot.png -->

- Sidebar with your backups and the backed-up Mac's home folders, Desktop, Documents, …
- Timeline of every backup; switching backups keeps you in the same folder
- Version history: select an item to see in which backups it changed, and jump between versions
- Quick Look, Get Info (with folder sizes), recursive search, Go to Folder using the original Mac's paths
- Restore to a folder, drag items to Finder, or ⌘C here and ⌘V in Finder
- Finder's keyboard conventions throughout (see below)

TimeFinder is strictly read-only: it never modifies a backup.

## Install

```sh
brew install --cask lnsp/tap/timefinder
```

TimeFinder isn't notarized by Apple (that requires a paid developer account), so macOS blocks the
first launch: open **System Settings › Privacy & Security** and click **Open Anyway** (needed
again after each upgrade). Then grant **Full Disk Access** when TimeFinder asks for it — release
builds are signed with a stable certificate, so that permission survives upgrades.

You can also download the zip from [Releases](https://github.com/lnsp/timefinder/releases) or build
it yourself (below).

## Requirements

- macOS 14 Sonoma or later
- **Full Disk Access** for TimeFinder (System Settings › Privacy & Security › Full Disk Access).
  macOS only lets apps with Full Disk Access mount Time Machine backups; TimeFinder shows a
  shortcut to the setting when it's needed.
- To build: Xcode 16 or later, selected with `xcode-select` (the Command Line Tools alone aren't enough)

## Build

Open `TimeFinder.xcodeproj` and press ⌘R, or:

```sh
scripts/build-app.sh            # Release build → build/TimeFinder.app (Debug: scripts/build-app.sh Debug)
open build/TimeFinder.app
```

### Signing

Out of the box the app is signed ad hoc ("Sign to Run Locally"), so no Apple Developer account
is needed. The catch: macOS ties Full Disk Access to the app's signature, and an ad-hoc signature
changes with every build, so you'd have to grant Full Disk Access again after each rebuild.

To avoid that, give your builds a stable signing identity in `Config/Local.xcconfig` (git-ignored):

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

and pick one of the two options in it: your Apple Developer team (a free Apple ID works), or a
self-signed code-signing certificate in your keychain — which is what releases use. Use
`Config/Local.xcconfig` rather than Xcode's Signing & Capabilities tab, which would write your
settings into the shared project file.

### Releasing

```sh
scripts/release.sh 1.2.3             # build, sign, verify, zip; renders the cask — publishes nothing
scripts/release.sh 1.2.3 --publish   # also tags v1.2.3, creates the GitHub release, updates the tap
```

The script builds a universal (Apple silicon + Intel) Release build with the hardened runtime,
signs it with the self-signed **TimeFinder Release Signing** certificate from your keychain
(override with `TIMEFINDER_SIGNING_IDENTITY`), checks the signature, version and entitlements, and
renders `packaging/homebrew/timefinder.rb` with the zip's checksum. Publishing uses the GitHub CLI
(`gh`) and commits the cask to [lnsp/homebrew-tap](https://github.com/lnsp/homebrew-tap).

Releases must always be signed with the same certificate: users' Full Disk Access permission is
tied to it, and a new certificate would make every user grant it again.

## How it works

1. Finds `*.sparsebundle` / `*.backupbundle` at the top level of mounted volumes, and remembers
   them — including the server URL, so it can reconnect an SMB or AFP share when it isn't mounted.
   Other images (`.sparseimage`, `.dmg`) can be opened with File › Open Backup….
2. Attaches the image read-only (`hdiutil attach -readonly -nomount`). For encrypted images the
   password comes from your keychain or the system's password dialog.
3. Mounts the backup volume read-only and hidden from Finder, and lists its
   `com.apple.TimeMachine.*.backup` APFS snapshots (macOS 11+ backups). Legacy HFS+
   `Backups.backupdb` backups are supported too, but less tested.
4. Mounts snapshots on demand (`mount_apfs -s … -o rdonly,nobrowse,noowners`) in a private
   temporary folder.
5. On eject or quit, unmounts everything it mounted and detaches the image.

**While a backup is open, the Mac it belongs to can't back up to it** — the disk image is locked
while attached. TimeFinder therefore ejects a backup automatically after 15 minutes in the
background; reopening it takes a moment.

Opening a backup over the network can take a while (often 30–60 s): the disk image consists of
thousands of small files that macOS reads one by one, so the network's latency matters more than
its speed.

### Cache

To make reopening fast, TimeFinder caches *metadata* from backups you've browsed — folder
listings and the fingerprints behind version history — never file contents. While a backup is
still connecting, the last-known timeline and folders you've visited appear immediately under a
banner that says they're cached and from when; previews, opening and restoring stay disabled
until the backup is connected, at which point everything is replaced by live data.

Cached data can't go stale: each entry is keyed by an APFS snapshot's UUID and transaction ID,
and a Time Machine snapshot never changes. The only thing that does change — which backups
exist — is always taken from the live backup once connected. As a safety net, live listings are
compared with cached ones and a snapshot's cache is discarded on any difference.

The cache lives in `~/Library/Caches/<bundle id>/Backups/` (user-only permissions) and contains
file names from your backups, including encrypted ones. Turn it off or clear it in Settings.

## Security & privacy

- TimeFinder needs Full Disk Access, which allows reading everything on this Mac. It uses it only
  to mount and read the backups you open.
- It runs Apple's own tools — `/usr/bin/hdiutil`, `/sbin/mount_apfs`, `/sbin/mount_hfs`,
  `/sbin/umount`, `/usr/sbin/diskutil`, and `/usr/bin/find` with `/bin/chmod` (to remove
  inherited ACLs from restored copies, never following symbolic links) — with fixed absolute
  paths, never through a shell and never with `sudo`.
- Backup passwords are passed to `hdiutil` on standard input, never on the command line.
- Snapshots are mounted with `noowners`, so every file in the backup is readable by you, and
  mounted under your per-user temporary folder.
- Remembered backups and their server URLs (including the user name, never the password) are
  stored in the app's preferences.
- File names and attributes from browsed backups are cached on this Mac unless you turn the
  cache off (see Cache above).
- No network access beyond reconnecting your own file shares. No analytics.

## Keyboard

| Keys | Action |
|---|---|
| Space · ⌘Y | Quick Look (↑/↓ keep moving through the list while it's open; Esc closes it) |
| Tab · ⇧Tab | Next / previous item alphabetically |
| type a name | Select the matching item |
| ⌘O · ⌘↓ · double-click | Open |
| ⌘↑ · ⌘[ · ⌘] · mouse buttons 4/5 | Enclosing folder · back · forward |
| ⌘I | Get Info (current folder if nothing is selected) |
| ⌘C · ⌥⌘C | Copy files (paste in Finder to restore) · copy as pathname |
| ⌘A · ⌥⌘A | Select all · deselect all |
| ⌘F | Search below the current folder |
| ⇧⌘G | Go to Folder (`~/Documents`, `/Users/name`, case-insensitive) |
| ⇧⌘C/H/D/O/A · ⌥⌘L | Computer · Home · Desktop · Documents · Applications · Downloads |
| ⌘R · ⇧⌘R | Show in Finder · Restore To… |
| ⌥⌘← / ⌥⌘→ | Older / newer backup (Go › Latest Backup jumps to the newest) |
| ⌥⇧⌘← / ⌥⇧⌘→ | Previous / next version of the selection |
| ⇧⌘. · ⌥⌘P · ⌃⌘S | Hidden files · path bar · sidebar |
| ⌘E · ⌥⌘O | Eject backup · open another backup |

## Known limitations

- Versions are detected from each item's identity, size and modification date in every backup
  (Time Machine gives changed items — and folders whose contents changed — a new identity).
- Search stops after 5,000 results.
- Symbolic links that point outside the backup (e.g. to `/Users/…` on the original Mac) aren't
  followed, so you never see this Mac's files by mistake.
- Snapshot dates are shown as recorded by the backed-up Mac (its local time).
- Less tested: entering the password of an encrypted backup when it isn't in your keychain, and
  legacy HFS+ (pre-macOS 11) backups.

## Debugging

```sh
# Log every hdiutil/diskutil/mount call (and cache cross-check) to a file:
open --env TIMEFINDER_DEBUG=1 --stderr /tmp/timefinder.log build/TimeFinder.app

# Preselect an item on launch:
open build/TimeFinder.app --args -TFSelect Data/Users/me/Desktop
```

Launch through `open` (or Xcode): starting the binary directly from Terminal makes macOS check
*Terminal's* Full Disk Access instead of TimeFinder's.

## License

Copyright 2026 Lennart Espe. Licensed under the [Apache License, Version 2.0](LICENSE).

TimeFinder is not affiliated with or endorsed by Apple Inc. Time Machine and Finder are trademarks
of Apple Inc., registered in the U.S. and other countries.

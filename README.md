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

To avoid that, sign with your own team (a free Apple ID works):

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored; fill in your team ID
```

Use `Config/Local.xcconfig` rather than picking a team in Xcode's Signing & Capabilities tab, which
would write your team into the shared project file.

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

## Security & privacy

- TimeFinder needs Full Disk Access, which allows reading everything on this Mac. It uses it only
  to mount and read the backups you open.
- It runs Apple's own tools — `/usr/bin/hdiutil`, `/sbin/mount_apfs`, `/sbin/mount_hfs`,
  `/sbin/umount`, `/usr/sbin/diskutil`, `/bin/chmod` (to remove inherited ACLs from restored
  copies) — with fixed absolute paths, never through a shell and never with `sudo`.
- Backup passwords are passed to `hdiutil` on standard input, never on the command line.
- Snapshots are mounted with `noowners`, so every file in the backup is readable by you, and
  mounted under your per-user temporary folder.
- Remembered backups and their server URLs (including the user name, never the password) are
  stored in the app's preferences.
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
- Encrypted backups and legacy HFS+ backups have had less testing than unencrypted APFS ones.

## Debugging

```sh
TIMEFINDER_DEBUG=1 open build/TimeFinder.app          # logs every hdiutil/diskutil/mount call to stderr
open build/TimeFinder.app --args -TFSelect Data/Users/me/Desktop   # preselect an item on launch
```

Launch through `open` (or Xcode): starting the binary directly from Terminal makes macOS check
*Terminal's* Full Disk Access instead of TimeFinder's.

## License

<!-- TODO: choose a license (e.g. MIT) and add LICENSE -->

TimeFinder is not affiliated with or endorsed by Apple Inc. Time Machine and Finder are trademarks
of Apple Inc., registered in the U.S. and other countries.

# QuickFolder

Your latest downloads, one hover away. Point at the MacBook notch and it opens
into a shelf of your most recent files. Click a file to open it, or drag it
anywhere.

## Install

```bash
scripts/install.sh
```

Builds a release app, copies it to `/Applications`, and launches it. The first
launch turns on Open at Login.

## Use

- **Point at the notch.** The island opens with your 40 newest downloads, newest first.
- **Click** a file to open it.
- **Drag** a file out to move it, like dragging out of Finder. Hold Option to copy. The island gets out of the way as soon as the file leaves it.
- **Right-click** for Open With, Show in Finder, Quick Look, Copy and Move to Trash.
- **Archives** (.zip, .tar.gz and friends) get a small button when you point at them: it extracts next to the archive and moves the archive to the Trash. One item inside lands as is; several go into a folder named after the archive. Nothing is ever overwritten.
- **Swipe sideways** to see older files (Shift-scroll with a mouse).
- **Swipe up or down** to switch folders: Downloads and Desktop to start, add more from ⋯. The shelf resists until you've swiped far enough, then clicks over one folder, so a sloppy sideways swipe never switches. With a mouse, a few wheel clicks in a row switch.
- **Haptics** on a Force Touch trackpad: a firm click when the island opens and when the folder changes, a light tick per file you point at, and a bump at the end of the shelf. Turn them off from ⋯.
- **Folder button:** opens the folder in Finder's column view, sorted by Date Added. Finder's column view only has one sort setting for every folder, so this sets column view to Date Added everywhere.
- **⋯ button:** jump to a folder, add or remove folders, turn off new-file previews or haptics, toggle Open at Login, or quit.

When a file lands in any of the folders, the notch briefly shows what arrived.
Hover it to open that folder's shelf.

On Macs without a notch, a small black notch appears at the top center of the
screen instead.

## Permissions

| Permission | Asked for when | Why |
| --- | --- | --- |
| Downloads and Desktop folders | First launch | To list your files |
| Automation → Finder | First click on the folder button | To open the folder in column view |
| Accessibility | First click on the folder button | To set Finder's sort to Date Added (Finder has no scripting command for column-view sorting) |

## Develop

```bash
swift build                                 # compile
CONFIG=debug scripts/build.sh               # build/QuickFolder.app, debug
QF_DEBUG_STATE=expanded build/QuickFolder.app/Contents/MacOS/QuickFolder   # keep the island open
QF_DEBUG_STATE=expanded QF_DEBUG_PAGE=1 build/QuickFolder.app/Contents/MacOS/QuickFolder   # open on the second folder
QF_DEBUG_STATE=peek     build/QuickFolder.app/Contents/MacOS/QuickFolder   # keep the new-download preview open
swift scripts/make-icon.swift               # regenerate Resources/AppIcon.icns
```

Builds are signed with the first Apple Development or Developer ID identity in
your keychain, so macOS keeps the permissions across rebuilds. Set
`SIGN_IDENTITY=-` for ad-hoc signing.

### Layout

| File | What it does |
| --- | --- |
| `IslandController.swift` | Window, hover detection, open/peek/close state, scrolling, menus |
| `IslandView.swift` | SwiftUI: the shape, shelf, tiles, and preview |
| `IslandModel.swift` | State and all geometry, derived from the notch |
| `NotchShape.swift` | The notch outline, with curves that blend into the screen edge |
| `MouseInteraction.swift` | AppKit hover, click and drag, since the app never becomes active |
| `DownloadsMonitor.swift` | Watches the folder and skips downloads that are still in progress |
| `ThumbnailStore.swift` | Quick Look thumbnails, Finder icons until they load |
| `FileActions.swift` | Open, reveal, trash, Quick Look, and the Finder column view |

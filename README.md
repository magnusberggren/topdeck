# TopDeck

Your latest downloads, one hover away. Point at the MacBook notch and it opens
into a shelf of your most recent files. Click a file to open it, or drag it
anywhere.

## Install

1. Download [TopDeck.dmg](https://github.com/magnusberggren/topdeck/releases/latest/download/TopDeck.dmg).
2. Open it and drag TopDeck to Applications.
3. Open TopDeck from Applications, then point at the notch.

It's notarized by Apple, so it opens without warnings.

From source: `scripts/install.sh` builds a release app, copies it to
`/Applications`, and launches it. The first launch turns on Open at Login.

TopDeck updates itself: every 6 hours it looks for a newer GitHub release,
checks it's signed by the same developer, swaps it in and restarts as soon as
the island closes (unless a call is about to start). ⋯ › Check for Updates…
updates right away, and the menu shows which version you have. If an update
can't go in, the notch says so. ⋯ › Update Automatically turns it off.

## Contribute

TopDeck is open source. Found a bug or have an idea? Use ⋯ › Report a
Problem… in the app, or [open an issue](https://github.com/magnusberggren/topdeck/issues/new/choose).
Want to change something yourself? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Release

```bash
scripts/release.sh
```

From a clean, pushed `main`: builds, signs with the newest Developer ID
certificate, has Apple notarize the app and the disk image, and publishes
`v1.<commit count>` with `TopDeck.dmg` (for people) and `TopDeck.zip`
(for the updater) to GitHub Releases. `scripts/package.sh` does everything
except publishing.

Notarizing needs a keychain profile, set up once per Mac:

```bash
xcrun notarytool store-credentials notary --apple-id <Apple ID> --team-id AURJLA4GTL
```

## Use

- **Point at the notch.** The island opens with your 40 newest downloads, newest first.
- **Click** a file to open it.
- **Drag** a file out to move it, like dragging out of Finder. Hold Option to copy. The island gets out of the way as soon as the file leaves it.
- **New-file preview:** when a file lands, the notch shows it for a few seconds. Point at the preview to keep it up, then click to open it or drag it straight out. Point at the notch itself to open the full shelf.
- **Meetings page:** your next two video calls (Google Meet, Zoom, Teams and more) from every account in the Calendar app, then Google Calendar and Google Drive for each of your Google accounts, each opening as that account. Click a call to join. Google Meet opens as the account that was invited, so you never have to switch accounts in the browser. Right-click for Join As, Copy Link and Show in Calendar. A minute before a call starts it pops out of the notch with a Join button; turn that off under ⋯ › Remind 1 Minute Before on the Meetings page. Only your own calendars count by default, not ones colleagues share with you; change that under ⋯ › Calendars. Add your Google accounts in System Settings › Internet Accounts if they aren't in Calendar yet.
- **Any display:** ⋯ › Show On puts the island on the display you choose. Displays without a notch (like a Mac Studio's) get a drawn notch at the top center, always visible.
- **Same setup on every Mac:** your Apple ID is the account. Shortcuts and settings (folders, row order, pages, reminders, hidden calendars) live in your own iCloud Drive, so installing TopDeck on another Mac signed in to the same Apple ID brings your setup along. Which display the island uses stays per Mac. Turn it off with ⋯ › Sync with iCloud. On the Shortcuts page, Export Shortcuts… and Import Shortcuts… share shortcuts with someone else as a file.
- **Right-click** for Open With, Show in Finder, Quick Look, Copy and Move to Trash.
- **Archives** (.zip, .tar.gz and friends) get a small button when you point at them: it extracts next to the archive and moves the archive to the Trash. One item inside lands as is; several go into a folder named after the archive. Nothing is ever overwritten.
- **Disk images** (.dmg) get an Install button: it mounts the image, copies the app to /Applications (an older version goes to the Trash), ejects, and trashes the .dmg. Images with a license agreement or an installer package open normally instead.
- **Live downloads:** while something downloads, the notch grows small wings with a progress ring and percentage, and the file sits at the front of its shelf with a ring. Works with any browser that reports progress to Finder (Safari, Chrome, Arc, Edge, Firefox); others get a spinner.
- **Clean Up:** when a folder holds installers (.dmg, .pkg) added more than a week ago, a pill in the header shows how much space they take. Click once to see what it'll do, again to move them all to the Trash.
- **Swipe sideways** to see older files (Shift-scroll with a mouse).
- **Swipe up or down** to switch rows: Downloads, Desktop and Shortcuts to start, add folders from ⋯. It goes around, so swiping up from the top row lands on the bottom one. The shelf resists until you've swiped far enough, then clicks over one row, so a sloppy sideways swipe never switches. With a mouse, each wheel notch switches one row, including smooth-scrolling mice like Logitech's.
- **Arrange rows:** click the row dots on the left (or ⋯ › Arrange Rows) and drag rows into the order you want. The top row is the one the island opens on.
- **Haptics** on a Force Touch trackpad: a firm click when the island opens and when the folder changes, a light tick per file you point at, and a bump at the end of the shelf. Turn them off from ⋯.
- **Folder button:** opens the folder in Finder's column view, sorted by Date Added. Finder's column view only has one sort setting for every folder, so this sets column view to Date Added everywhere.
- **⋯ button:** jump to a folder, add or remove folders, hide the Shortcuts page, turn off new-file previews or haptics, toggle Open at Login, or quit.

### Shortcuts page

Swipe past your folders to a deck of big keys, like a Stream Deck. A key can:

- **Paste Text:** types a saved prompt or snippet into whatever text field you're in, optionally pressing Return. `{clipboard}`, `{date}` and `{time}` are filled in.
- **Open Website** or **Open App**.
- **Run Shortcut:** anything from the Shortcuts app.
- **Run Command:** a zsh command.

Click **+** to add one; right-click a key to edit, duplicate, reorder or delete it. The editor supports the usual ⌘C, ⌘V, ⌘A and ⌘Z.

When a file lands in any of the folders, the notch briefly shows what arrived.
Hover it to open that folder's shelf.

On Macs without a notch, a small black notch appears at the top center of the
screen instead.

## Privacy

TopDeck has no server and no account of its own. Your files, calendar and
shortcuts stay on your Mac and in your own iCloud Drive. The only thing it
asks the internet for is whether there's a newer version on GitHub.

## Permissions

| Permission | Asked for when | Why |
| --- | --- | --- |
| Downloads and Desktop folders | First launch | To list your files |
| Automation → Finder | First click on the folder button | To open the folder in column view |
| Accessibility | First click on the folder button or a Paste Text key | To set Finder's sort to Date Added, and to press ⌘V for Paste Text |
| Removable volumes | First Install | To look inside the mounted disk image |
| App Management | First Install that replaces an existing app | macOS protects installed apps from being replaced |
| Calendars | Allow Calendar Access on the Meetings page | To list your upcoming video calls |
| iCloud Drive | First launch, while Sync with iCloud is on | To keep your setup in iCloud Drive/TopDeck |

## Develop

```bash
swift build                                 # compile
CONFIG=debug scripts/build.sh               # build/TopDeck.app, debug
QF_DEBUG_STATE=expanded build/TopDeck.app/Contents/MacOS/TopDeck   # keep the island open
QF_DEBUG_STATE=expanded QF_DEBUG_PAGE=1 build/TopDeck.app/Contents/MacOS/TopDeck   # open on the second folder
QF_DEBUG_STATE=expanded QF_DEBUG_ACTIONS=1 …   # also: QF_DEBUG_RUNKEY=n (+ QF_DEBUG_FRONT=<bundle id>), QF_DEBUG_EDITOR, QF_DEBUG_ARRANGE, QF_DEBUG_CONFIRM, QF_DEBUG_MENU
QF_DEBUG_STATE=peek     build/TopDeck.app/Contents/MacOS/TopDeck   # keep the new-download preview open
QF_DEBUG_STATE=meetingpeek …                   # the meeting reminder, with a sample call
QF_DEBUG_STATE=expanded QF_DEBUG_MEETINGS=1 …  # Meetings page with sample calls, no Calendar access needed
QF_DEBUG_FAKE_NOTCH=1 …                        # draw the island as on a display without a notch
QF_DEBUG_RELEASE=file:///path/latest.json …   # try an update from a local release JSON
swift scripts/make-icon.swift               # regenerate Resources/AppIcon.icns
```

Builds are signed with the newest Developer ID certificate in your keychain,
else an Apple Development one, else ad-hoc, so macOS keeps the permissions
across rebuilds. Set `SIGN_IDENTITY=-` to force ad-hoc signing. Only builds
signed by the maintainer update themselves.

### Layout

| File | What it does |
| --- | --- |
| `Meetings.swift` | Upcoming video calls from Calendar, and which account to join as |
| `CloudSync.swift` | Shortcuts and settings files in iCloud Drive, and shortcut export |
| `Updater.swift` | Self-update from GitHub Releases, with a signature check |
| `IslandController.swift` | Window, hover detection, open/peek/close state, scrolling, menus |
| `IslandView.swift` | SwiftUI: the shape, shelf, tiles, and preview |
| `IslandModel.swift` | State and all geometry, derived from the notch |
| `NotchShape.swift` | The notch outline, with curves that blend into the screen edge |
| `MouseInteraction.swift` | AppKit hover, click and drag, since the app never becomes active |
| `DownloadsMonitor.swift` | Watches the folder and skips downloads that are still in progress |
| `ThumbnailStore.swift` | Quick Look thumbnails, Finder icons until they load |
| `FileActions.swift` | Open, reveal, trash, Quick Look, archives, and the Finder column view |
| `SmartActions.swift` | Per-file-type buttons and the disk image installer |
| `DownloadProgress.swift` | Listens for the download progress browsers report |
| `Deck.swift`, `DeckEditor.swift` | Shortcuts keys: storage, running them, and the editor window |

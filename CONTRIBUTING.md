# Contributing to TopDeck

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Report a problem or suggest something

- In the app: ⋯ › **Report a Problem…** opens a GitHub issue with your
  TopDeck and macOS versions filled in.
- Or open an [issue](https://github.com/magnusberggren/topdeck/issues/new/choose)
  directly. Screenshots or a screen recording help a lot.

## Make a change

You need a Mac with macOS 14 or later and Xcode (or the Command Line Tools:
`xcode-select --install`). No Apple developer account is needed.

1. Fork the repo and clone your fork.
2. Build and run:
   ```bash
   CONFIG=debug scripts/build.sh
   open build/TopDeck.app
   ```
   Quit the installed TopDeck first (⋯ › Quit TopDeck); only one copy runs at a time.
3. Make your change on a branch, and try it in the running app. The debug
   flags in the README's [Develop](README.md#develop) section pin the island
   open, fill the Meetings page with sample calls, and so on.
4. Check it compiles both ways:
   ```bash
   swift build && swift build -c release
   ```
5. Open a pull request against `main`. Say what changed and how you tried
   it, and add a screenshot for anything visible. CI builds every pull request.

Builds from source are ad-hoc signed unless you have your own signing
certificate. They never update themselves, so your build stays your build.

## How the code is written

- Match the code around your change: its naming, its comment style (short
  comments that say *why*), and its SwiftUI and AppKit patterns.
- Keep TopDeck private by design: no servers, no analytics, no accounts.
  Data stays on the Mac and in the user's own iCloud Drive.
- Interactive views overlay `MouseInteraction` rather than SwiftUI gestures,
  because the island never activates the app. See `MouseInteraction.swift`.
- The README's [Layout](README.md#layout) table says what each file does.

## Releases

Releases are signed and notarized with the maintainer's Developer ID, so
only the maintainer publishes them (`scripts/release.sh`). Once your pull
request is merged, it ships in the next release, and every installed copy
updates itself.

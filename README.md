# Down

A GNOME Files–style file manager for macOS 26+, written in Swift with AppKit and SwiftUI. It builds with the **Command Line Tools only** (no Xcode).

- Nautilus-like layout: sidebar, a header bar with an editable path bar, and a floating selection overlay
- GNOME shortcuts translated for macOS (Ctrl → ⌘, Alt → ⌥), all remappable
- Drag and drop with any app. While dragging, hover over a folder, a sidebar entry or a breadcrumb to spring-load into it.
- Copy / cut / paste files, compatible with Finder's pasteboard
- System / Light / Dark themes, pinned folders, external drives with eject, Open in Terminal
- Built-in Debug Console (Settings → Advanced) with live logs, tab state and performance timings

> Status: early development (milestones 1–3 of 9). Grid and column views, the full file-operation queue
> (conflict dialog, progress, undo), Quick Look, search and tabs polish are still to come.

## Build and run

Requirements: macOS 26 and the Command Line Tools (`xcode-select --install`). Down has no third-party dependencies.

```bash
make run          # debug build, launches in the foreground with debug logs on stderr
make app          # release build → build/Down.app
make install      # → ~/Applications/Down.app and ~/.local/bin/down
make test         # unit + ViewModel + in-process AppKit tests
make test-integration   # adds real-filesystem tests (temp dirs, FSEvents, copyfile)
```

macOS remembers privacy grants (Desktop, Documents, external drives) per code signature. Ad-hoc signatures change on every build, so you'd be asked again after each rebuild. To avoid that, create a stable local signing identity once (this adds a certificate to your login keychain):

```bash
scripts/make-dev-cert.sh
```

## Launching from a terminal

`open Down.app` detaches the process, so its log output never reaches your terminal. Use the shim instead:

```bash
down ~/src --log-level debug          # or DOWN_LOG=debug,ops=trace down
down --debug                          # Debug Console + verbose logging for this session
down --snapshot /tmp/down.png         # render the window to a PNG and quit (bug reports)
```

Unified log: `log stream --predicate 'subsystem == "app.down"' --level debug` (file paths are redacted there).

## Shortcuts

| Action | Keys | Action | Keys |
|---|---|---|---|
| Location entry | ⌘L, or type `/` `~` | Back / Forward / Up | ⌥← ⌥→ ⌥↑ |
| Open | ↩, ⌘O, ⌥↓ | Home | ⌥Home, ⇧⌘H |
| Hidden files | ⌘H, ⇧⌘. | Reload | ⌘R, F5 |
| New tab / window / close | ⌘T ⌘N ⌘W | Tab N | ⌥1…9 |
| Copy / Cut / Paste | ⌘C ⌘X ⌘V | Pin current folder | ⌘D |
| Toggle sidebar | F9 | Open in terminal | ⌘⌥T |
| First / last item | Home, End (fn←, fn→) | Page up / down | PgUp, PgDn (fn↑, fn↓) |
| Debug Console | ⌥⌘J (when enabled) | Settings | ⌘, |

Home, End, Page Up and Page Down move the selection (not just the scroll position), like GNOME Files. Add ⇧ to extend the selection.

⌘H shows hidden files (GNOME's Ctrl+H), so "Hide Down" in the app menu has no shortcut.

## Architecture

MVVM with one-way data flow: **View → Action → ViewModel → State → View**.

- `DownCore`: models, services (actors behind protocols), logging. It imports no AppKit or SwiftUI.
  - Listing uses `getattrlistbulk(2)` through a small C shim (`CDirent`) and streams batches.
  - Live updates come from FSEvents (`DirectoryWatcher`).
  - Sorting uses precomputed natural-order collation keys.
- `DownUI`: `@MainActor @Observable` ViewModels, plus AppKit views (list, sidebar, path bar) and SwiftUI (settings).
  - Each ViewModel has a single `send(_:)` mutator. Slow work runs as keyed effects whose results come back as actions.
- `DownTestSupport`: fakes (`FakeFileSource`, `FakeWorkspace`), `TempDir`, `TestLogSink`.

## Security

- Hardened runtime with no entitlement exceptions. Down is not sandboxed: a general-purpose file manager can't work inside the App Sandbox.
- No shell strings anywhere. Files open through LaunchServices, and Open in Terminal hands the folder to the terminal app (no AppleScript).
- Copies use `copyfile(3)`: they clone on APFS, keep quarantine and other extended attributes, never follow symlinks, and never overwrite existing files.
- File names containing control characters or bidi overrides are shown with visible escapes.

## License

MIT (see LICENSE).


## Attribution

Alejandro Mantilla 2026

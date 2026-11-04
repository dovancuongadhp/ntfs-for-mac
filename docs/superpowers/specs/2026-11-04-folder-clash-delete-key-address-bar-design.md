# File Transfer: same-name folders, ⌘⌫, typed addresses

Approved 2026-11-04.

## A folder that is already there

- Before a copy starts, every copied folder (top level of what was chosen) whose name already exists in
  the destination is asked about, one at a time: Keep Both (copied as "Name 2", "Name 3"…, like
  Finder), Merge (into the existing folder, files asked about one by one as before), Skip, or Cancel the
  whole copy. "Apply to all" answers the rest. Return means Keep Both.
- No Replace: removing the existing folder loses data too easily.
- Core: `TransferPlanner.clashingFolders(sources:into:access:)` finds them;
  `plan(…, folderChoices:)` takes the answers keyed by source path.
- The question is asked by `TransferSession` (`folderClash`, answered with `answerFolderClash`), so it is
  testable without the view.

## Delete keys

- An `NSEvent` key monitor on the File Transfer page handles ⌘⌫ (Trash) and Shift+⌫, Shift+⌦, ⌥⌘⌫
  (delete immediately, after confirming) when a pane's list has keyboard focus. Text fields keep these
  keys. Replaces the SwiftUI `onKeyPress` handler, which never received ⌘⌫.
- The key-to-action mapping is a pure function, unit tested.

## Address bar

- Clicking a pane's path, or ⌘L for the active pane, turns it into a text field.
- Suggestions follow the typing: the sub-folders of the typed parent whose names start with the last
  typed part, case-insensitive; hidden ones only once a "." is typed; at most 20. Choosing one fills in
  its path with a trailing "/" so typing can continue. `~` is the home folder.
- Return opens the folder; a path that is not a folder turns the field red and keeps the text. Esc, or
  leaving the field, cancels.
- The suggestions are our own list under the field (the system popup can't tell which row is
  highlighted). Tab completes the highlighted row, the first until ↑ ↓ pick another, and keeps typing
  going; Return opens the picked row, else the typed path. Click fills in a row, double-click opens it.
- Core: `PathCompletion.suggestions(for:home:)`, `PathCompletion.folder(for:home:)` and
  `PathSuggestions` (highlight, Tab completion, picked row), unit tested.

## Collapsible progress panel

- The panel always has a bar with a ▸/▾ button (double-clicking the bar works too), a one-line status
  ("No copies yet", the headline, plus a small bar and percentage while collapsed and copying, and the
  error count in red once anything failed) and the Options menu. Collapsed, only the bar shows.
- The choice is remembered (`TransferProgressCollapsed`) and only the person changes it: a new copy does
  not open the panel.

## Progress grouped by copy

- Each copy the person asks for (Copy, paste, drop) is a group. The queue records where each copy's job
  numbers start, its start time and its From/To folders (those of the items picked); a job belongs to
  the last copy starting at or before it, so retried files stay in their own copy.
- `TransferQueue.groups`: newest first, each with its items, totals (`TransferProgress`) and a status:
  waiting (queued behind another copy), copying, or over. `clear()` forgets them.
- The table shows one disclosure row per copy using the same columns: "Copy at <time>" with the file
  count, From, To, total size, and percent / Waiting / Done / Errors: n. Its files are inside. The newest
  copy is open, older ones closed, unless the person opened or closed them. The All/Copying/Errors
  filter applies to the files; a copy left with none is hidden.
- The log outlives the app: `TransferQueue.log` / `restore(_:)` and `TransferLog` save it as JSON in
  Application Support (`TransferLog.json`) when a copy ends or halts and when the app quits, and read it
  back at launch. Files under way at quit come back skipped; their failures can still be retried. Only
  Clear (`TransferSession.clearLog()`) empties it. Tests pass no log URL, so they never touch it.
- Compact layout, top-aligned: the bar holds the status, and when open also the All/Copying/Errors
  filter and Clear (disabled while a copy runs or is halted) beside Options. Under it, one summary line
  (progress, sizes, speed, Pause/Skip/Cancel, or the result) only once a copy has started; then the
  table, whose empty state is the drag hint or "Nothing is being copied." / "No errors."; then the
  Retry/Export row only while something failed. Idle with a kept log, the status reads
  "Earlier copies: n".

## Welcome page

- A Welcome row heads the sidebar (`SidebarSelection.welcome`), and the window opens on it every time
  it is opened, the first launch and the extension reminder included; an invalid or empty selection
  falls back to it.
- It shows the app icon, name, tagline and version; whether the NTFS driver is on (with Turn It On
  leading to Settings when off); the external drives' partitions with file system and size, each
  opening its page; and rows leading to File Transfer and Settings.

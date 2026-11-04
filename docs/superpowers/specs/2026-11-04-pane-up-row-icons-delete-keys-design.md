# File Transfer panes: ".." row, Finder icons, delete keys

Approved 2026-11-04.

## ".." row

- When the pane's folder has a parent, the list starts with a row named "..", whatever the sort order.
- Double-click or Return on it opens the parent folder (`goUp`).
- It is not an item: it cannot be dragged, and Copy, Copy to the Other Side, Rename, Delete and Quick Look
  leave it out. A selection of only ".." counts as nothing selected (footer, toolbar, context menu).
- The model exposes it as `FileBrowserModel.parentURL` (nil at `/`) and `actionableSelection`
  (the selection without it); the session's `can…` checks use `actionableSelection`.

## Icons

- Rows show the system icon of each item (`NSWorkspace.icon(forFile:)`), 16 pt, cached by path.
- The places menu and its button show the system icon of each place (home, Desktop, drives…).
- The ".." row shows an up-arrow symbol.

## Delete keys

- ⌘⌫: move to the Trash (as Finder). The plain Delete key keeps doing the same.
- Shift+⌫, Shift+forward-delete and ⌥⌘⌫: delete permanently after a confirmation whose default
  button is Cancel. Protected items (volume roots, system folders, home) are refused, as for the Trash.
- The context menu gains "Delete Immediately…" under "Move to Trash", with the shortcuts shown.
- The confirmation says the deletion can't be undone; the existing "can't be moved to the Trash" wording
  stays for volumes without a Trash.

## Tests

- Core: `parentURL` at a folder and at `/`; `actionableSelection` drops the parent.
- App: only ".." selected disables Copy, Rename, Delete, Quick Look; permanent delete asks first,
  refuses protected items, and deletes after confirmation.

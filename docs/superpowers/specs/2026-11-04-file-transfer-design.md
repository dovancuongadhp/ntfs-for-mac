# File Transfer (Beta) — Design

Date: 2026-11-04 · Target release: 2.2.0 Lotus

## Goal

Add a **File Transfer** page to the main window: two file browsers side by side, and a progress panel below. The user copies files between any two locations (an NTFS drive, another drive, a folder on the Mac) by dragging, or with a Copy button, and sees progress, read and write speed, which files finished, which files failed, and a notification when everything is done. The page is marked **Beta** in the sidebar and in its title.

## Decisions made with the user

| Question | Decision |
| --- | --- |
| Layout | Two full file browsers (like Commander One / Total Commander) with the progress panel underneath |
| "Continue" button | Pause / Resume while copying, retry the files that failed, and a prompt on error (Skip / Retry / Stop, with "apply to all") |
| Finding damaged files | Read and write errors and size mismatches always; an optional **Verify after copy** switch compares checksums |
| Operations | Copy, name-conflict handling, new folder, rename, delete, Quick Look, Show in Finder |
| Not in the first version | Move (cut and paste), resuming after the app quits, folder sync, compression, parallel queues |
| Placement | New sidebar item **File Transfer** with a **Beta** badge, above the drive list |

## Placement and the Beta mark

- The sidebar gets one extra row at the top, **File Transfer**, with the icon `arrow.left.arrow.right` and a small **BETA** capsule at the trailing edge of the row.
- The page title repeats the mark: "File Transfer" followed by the same capsule.
- The first time the page opens, a one-line dismissible banner says: "File Transfer is in beta. Keep a second copy of anything important." The choice to dismiss is remembered.
- `Beta` is a proper noun and stays "Beta" in Vietnamese.
- `MainWindowView` gains a selection case for this page next to the existing drive selections, and `keepSelectionValid` keeps it valid. The toolbar shows the page's own actions (Copy, New Folder, Rename, Delete, Quick Look, Show in Finder) while it is selected; Mount, Unmount, Eject and Format are disabled, as they are on the Settings page.

## Layout

```
Toolbar: [Copy ▶] [New Folder] [Rename] [Delete] [Quick Look] [Finder]
┌ Left pane ───────────────────────────┬ Right pane ─────────────────────────┐
│ [Drive ▾]  ‹ ›  path                 │ [Drive ▾]  ‹ ›  path                │
│ Name        Size      Date           │ Name        Size      Date          │
│ …                                    │ …                                   │
│ 2 selected · 8.0 GB                  │ 12 items · 1.3 GB free              │
├──────────────────────────────────────┴─────────────────────────────────────┤
│ Progress panel: overall bar, bytes, files, time left, read/write speed     │
│ [Pause] [Skip this file] [Cancel]            Filter: All · Copying · Errors│
│ per-file list with status, and [Retry failed] [Export error list]          │
└─────────────────────────────────────────────────────────────────────────────┘
```

- Each pane picks any mounted volume or a place on the Mac (Home, Desktop, Downloads), then browses folders. Selection is multiple. Columns sort by name, size and date.
- Copy works three ways: drag from one pane to the other, the **Copy** button (active pane to the other pane), or ⌘C then ⌘V. Dragging from Finder onto a pane also works.
- Below about 900 pt wide, the two panes stack vertically. The sidebar still folds as it does now.
- The progress panel can be resized and collapsed. It is empty and collapsed until a copy starts.

## Components

Each unit has one purpose and is tested on its own. They live in existing target folders; because `xcodegen` is not installed, new `.swift` files must be added to `NTFSForMac.xcodeproj/project.pbxproj` by hand (or the code goes into existing files).

1. **`TransferEngine`** (no UI): takes a list of jobs, copies them one file at a time on a background task, and emits events: file started, bytes done, read and write speed, file finished, file failed, paused, finished.
   - Reads and writes in 4 MB chunks through a small `FileAccess` protocol (the real one uses POSIX calls; tests use a fake that can fail on chosen files).
   - Writes each file to a temporary file beside the destination (`.name.ntfs-part`), checks it, then renames it to the real name. Unplugging the drive never leaves a half-written file under the real name.
   - Copies dates and permissions with `copyfile` after the data. Extended attributes and resource forks are not copied to NTFS or exFAT, so no `._name` files appear.
   - Symbolic links stay links; they are not followed.
   - With **Verify after copy** on, it hashes the source while reading and the destination after writing (SHA-256) and compares them.
2. **`TransferQueue`** (observable state for the UI): holds each item's state (`waiting`, `copying`, `done`, `failed`, `skipped`), totals, percentage, speeds, time left, the failure list, and the commands pause, resume, skip, cancel and retry-failed.
3. **`ConflictResolver`**: when a name exists, asks Replace / Keep both / Skip / Replace only if newer, with "Apply to all". Keep both appends " 2", " 3" and so on.
4. **`TransferPreflight`**: before copying, checks free space on the destination, names NTFS would reject (`: * ? " < > \ |`, trailing space or dot, DOS names), and files over 4 GB headed for FAT32. Problems are reported before the first byte is copied.
5. **`FileBrowserModel`** (one per pane): current folder, history, selection, sort, drive picker, and the folder listing.
6. **Views**: `TransferPage` (the two panes and the panel), `FilePaneView`, `TransferProgressPanel`, `ConflictPrompt`.
7. **`TransferNotifier`**: system notification when a copy ends, Dock progress, and a sleep assertion while copying. It reuses `App/Support/Notifier.swift`.

## Error handling

| Failure | Behaviour |
| --- | --- |
| A file cannot be read (bad sector, I/O error) | Marked "Damaged file", temporary file removed, copy continues with the next file |
| Destination out of space | Stops everything and says how much is missing |
| Drive unplugged or unmounted | Pauses; waiting files stay waiting; **Resume** after reconnecting |
| No permission | File marked failed, copy continues |
| Name not valid on the destination | Asks Rename or Skip |
| Checksum mismatch (Verify on) | Copy removed, file marked "data did not match", can be retried |

By default an error skips that file and the run continues, then a summary is shown. A setting switches to **Ask on error** with Skip / Retry / Stop and "Apply to all".

Pause stops at a chunk boundary (under a second) and keeps the temporary file and its write position, so Resume continues from the same place. Quitting while a copy is running asks for confirmation, then cancels and removes the temporary files.

Deleting moves items to the Trash. A volume without a Trash (NTFS) asks for confirmation before deleting for good.

## Notifications

- Done: "Copied 14 files (5.3 GB) in 4 min 12 s". With failures: "12 files copied, 2 failed". Clicking it opens the error list.
- The Dock icon shows progress. When the window is closed, the menu bar menu shows one status line.
- **Prevent sleep while copying** is on by default.

## Testing

- `TransferEngine` against temporary folders: many files, nested folders, empty files, files larger than one chunk, each conflict choice, pause and resume, cancel, checksum match and mismatch.
- A fake `FileAccess` throws on chosen files to cover: continue after a read error, out of space, drive removed, retry of failed files.
- `TransferQueue`: totals, percentage, speed and time left with a fake clock.
- `TransferPreflight`: invalid names, FAT32 limit, free space.
- By hand on real drives (NTFS_CUONG_2 on the Lexar E6): a large file, unplugging mid-copy, a forbidden name, then Verify on and off.

## Release plan

Branch `release-2.2.0-lotus`. Build in small steps, each with passing tests: engine, queue, preflight and conflicts, one pane, two panes with drag and drop, progress panel, notifications, then the Beta badge and the first-run banner. Vietnamese strings are added to `Localizable.xcstrings` with each step.

## Out of scope for now

Move, resuming after the app quits, folder sync, compression, and running several queues at once. The queue copies one file at a time; more threads are added only if copying turns out slow.

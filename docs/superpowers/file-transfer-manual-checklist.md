# File Transfer (Beta): manual checklist

Things the automated tests cannot prove: real drives, real windows, notifications, the Dock. Run this once on a
signed local build (`scripts/build-local.sh`, then install) before releasing 2.2.0. Write what you saw next to each
item; anything that fails is a bug to fix in the task that owns it, with a test first where the logic lives in the
package.

**You need:** the Mac, an NTFS drive (the Lexar E6, volume `NTFS_CUONG_2`), an exFAT drive (`SSD-PUBLIC`), a
1 GB or larger test file, and a folder with a few files and one subfolder. Never run this on the only copy of
anything.

Notation: **Result** is what you should see. Tick the box when it did.

## A. The page and the Beta notice

- [ ] **A1. Sidebar and title.** Open the app. *Result:* the sidebar shows **File Transfer** with an orange BETA
  capsule, above the drive list. Opening it shows the title with the same capsule.
- [ ] **A2. This is Beta notice.** On first opening, a notice banner says File Transfer is a Beta. Dismiss it, quit
  the app, open it again. *Result:* the banner stays dismissed.
- [ ] **A3. Narrow window.** Drag the window narrower. *Result:* the sidebar hides, and below about 900 pt wide the
  two panes stack one above the other (and go side by side again when widened). Folders and selections survive the
  switch.

## B. Copying

- [ ] **B1. One file by drag.** Left pane on Home, right pane on `NTFS_CUONG_2`. Drag one file from left to right.
  *Result:* the progress panel opens, shows the percentage, the read and write speeds and the time left. At the end a
  notification says "Copy complete" and the panel shows files copied, size and time.
- [ ] **B2. Several files and a folder.** Select three files and one folder with files inside, press **Copy**.
  *Result:* all arrive on the right with the same modification dates; the folder keeps its structure.
- [ ] **B3. Multi-row drag.** Select three rows in one pane and drag them (grab one of the selected rows).
  *Result:* all three are copied, not only the row under the pointer. Dragging an unselected row copies only that
  row.
- [ ] **B4. ⌘C and ⌘V, and Finder drops.** Select files in one pane, press ⌘C, click the other pane, press ⌘V.
  Then drag a file from a Finder window onto a pane. *Result:* both copy into the folder the pane shows.
- [ ] **B5. Drops that do nothing.** Drag a web link from a browser onto a pane; drag a file or folder onto the
  pane (folder) it is already in. *Result:* nothing is copied and no "name 2" appears. Dropping a mix of items
  already there and new ones copies only the new ones.
- [ ] **B6. Pause and Resume (large file).** Copy a file of 1 GB or more. Press **Pause**. *Result:* the numbers
  stop, and the read and write speeds disappear while paused. Press **Resume**: it carries on. When done,
  `shasum -a 256` of both files matches.
- [ ] **B7. Skip, Cancel.** During a large copy of several files, press **Skip**: the current file is marked
  skipped and the next one starts. Start another copy and press **Cancel**. *Result:* the headline reads "Copy
  cancelled" (never "Copy complete"), and no unfinished temporary file is left in the destination.
- [ ] **B8. Verify after copy.** Turn on **Verify after copy** in the options menu and copy a few files.
  *Result:* it takes longer and finishes without errors.
- [ ] **B9. Preventing sleep.** Start a long copy and run `pmset -g assertions` in Terminal. *Result:* an assertion
  with the reason "Copying files" (or "Đang sao chép tệp" in Vietnamese) is listed while copying, and gone after the
  copy ends, after Cancel and while the copy is stopped for lack of space.
- [ ] **B10. Dock and menu bar.** During a copy, the Dock icon shows the progress, and the menu bar menu shows
  "Copying files… NN%". *Result:* both update and disappear when the copy ends.

## C. Conflicts and errors

- [ ] **C1. Conflict choices.** Copy the same file again to the same place. *Result:* the conflict sheet appears.
  Test **Keep Both**, **Skip** and **Replace If Newer** once each. Try **Apply to all** with several conflicting
  files: the choice is applied to all of them.
- [ ] **C2. Return key means Skip.** On the conflict sheet, press Return. *Result:* the default button is **Skip**
  (nothing is replaced). Esc and a click outside do nothing; the sheet can only be closed by answering.
- [ ] **C3. Apply to all starts unchecked.** After answering one conflict, open the next one. *Result:* **Apply to
  all** is unchecked again, and a click on the old sheet's buttons never answers the new question.
- [ ] **C4. Ask on errors.** Turn on **Ask what to do on errors** and cause a read error (a damaged file, or the
  Flaky test as a reference). *Result:* a prompt offers **Retry**, **Skip** and **Stop**; **Return picks Skip**.
- [ ] **C5. Failed files.** With the prompt off, cause the same error. *Result:* the file shows red with the reason,
  the run continues, and the failed-files footer appears. **Retry Failed** copies them again when the cause is gone,
  and **Export Error List…** saves a text file (proposed name "Transfer errors.txt", or "Lỗi sao chép tệp.txt" in
  Vietnamese).
- [ ] **C6. Names the destination cannot hold.** Copy a file named `a:b.txt` to the exFAT volume (`SSD-PUBLIC`).
  *Result:* the "Can't copy everything" alert names it, and **Copy the Rest** copies the others. The same file to
  the NTFS volume copies without the alert. A file over 4 GB to a FAT32 drive is listed as too large.
- [ ] **C7. Not enough space.** Copy more data than the destination holds (a small stick or a disk image works).
  *Result:* the alert warns about the space and offers **Copy Anyway** (and Cancel). It never blocks. After
  **Copy Anyway**, when the drive fills up the copy stops with "The destination is full", shows the hint "Free some
  space, then resume the copy." and a **Resume** button; after freeing space, **Resume** finishes the copy.
- [ ] **C8. Drive unplugged.** Pull the destination drive's cable during a large copy. *Result:* the panel says a
  drive was disconnected, shows "Reconnect it, then resume the copy." and offers **Resume**. Reconnect, press
  **Resume**: the file restarts and finishes. No `.ntfs-part` files remain on the drive.

## D. Attention: when the app needs you

- [ ] **D1. Sidebar dot.** Start a copy that raises a conflict, then switch to another sidebar page (a drive, or
  Settings). *Result:* the File Transfer row shows an orange dot (tooltip and VoiceOver: "Needs your answer"). It
  goes away as soon as the question is answered. The same dot shows for a copy stopped by a full or removed drive,
  until Resume or Cancel. While copying normally the row shows the small spinner instead. Check light and dark
  mode and the selected-row highlight.
- [ ] **D2. Banner while the app is active.** Repeat D1 while NTFS for Mac is the frontmost app. *Result:* a
  notification banner (with sound) appears even though the app is active. "Copy complete" also shows as a banner
  while active. (Check System Settings > Notifications allows NTFS for Mac.)
- [ ] **D3. Window closed or another app.** Start a conflict, then (separately) close the window, and (separately)
  switch to another app. *Result:* a notification "Copying is waiting for you" appears; the Dock icon bounces where
  a Dock icon exists (not when the window is closed and the app is only in the menu bar); the menu bar menu shows
  "File copy is waiting for your answer" and clicking it opens the window.

## E. Panes, files and protection

- [ ] **E1. Context menu.** Right-click in both panes. *Result:* Open, Rename, New Folder, Move to Trash and Show in
  Finder all work. A right-click on a row outside the selection acts on that row, not on the old selection. Space
  opens Quick Look.
- [ ] **E2. Delete on NTFS.** Delete a file on the NTFS volume. *Result:* the alert names the item (or counts
  several and lists up to three names) and says it will be deleted permanently, because the Trash is not available
  there. On the Mac's own disk the item goes to the Trash.
- [ ] **E3. Protected items.** Select a volume root (`/Volumes/<name>`), a system folder (`/System`, `/Library`,
  `/Applications`, `/Users`, `/usr`…) and your home folder. *Result:* Rename and Delete are disabled for each (also
  the Delete key). The contents of those folders can still be renamed, deleted and copied, and copying *from or to*
  any of them is allowed.
- [ ] **E4. Refresh and ⌘R.** Add a file to a folder from Finder while a pane shows it. Press the pane's **Refresh**
  button, then add another and press ⌘R. *Result:* both show the new file; ⌘R works for the active pane and is not
  swallowed by another control.
- [ ] **E5. Unmounting a shown drive.** Eject or unmount a drive that a pane is showing. *Result:* the pane falls
  back to the Home folder (not an empty `/Volumes/<name>`); the window does not hitch. Plug the drive in again: it
  shows in the pane's locations.
- [ ] **E6. Panel layout.** *Result:* the panel is collapsed until the first copy, expands when a copy starts, and
  the divider position is sensible; after a copy the finished panel shows count, size and time. The All, Copying
  and Errors filter work.
- [ ] **E7. VoiceOver labels.** Turn on VoiceOver. *Result:* Back, Forward, Enclosing Folder and Refresh are read
  by name.
- [ ] **E8. Big copy.** Copy a folder of 50,000 or more small files. *Result:* the window and the panel stay
  responsive and the list scrolls smoothly.

## F. Quit and language

- [ ] **F1. Quit during a copy.** Press ⌘Q during a copy. *Result:* "Files are still being copied". **Keep Copying**
  leaves the copy running; **Quit** cancels, removes the unfinished file and exits only when that is done. Quit
  with no copy exits at once. Quit while formatting still shows the formatting alert.
- [ ] **F2. Vietnamese.** Set the language to Vietnamese (Settings, or the system language). Look through the page,
  the sidebar and menu, the panel in every state (running, paused, cancelled, stopped, finished with errors), the
  toolbar tooltips, the alerts and sheets. *Result:* no untranslated English except "BETA".

## Known limits (recorded for the final review)

Not bugs to fix before the Beta; do not expect them to be fixed by this checklist.

- **Copy only.** There is no Move. Dragging a selection of rows relies on the table handing over the whole
  selection; the app falls back to the other pane's selection when only one URL arrives.
- **Ignored drops are silent.** A drop that is refused or filtered (web links, items already in the folder) gives
  no message.
- **`pageVisible` for a minimised window** counts as visible, so a question raised while the window is minimised
  may not trigger the notification and Dock bounce.
- **Apply to all and Skip by Return.** Return picks Skip for a single question; "Apply to all" with Skip from the
  keyboard is not special-cased.
- **After a drive is removed, the file restarts** from the beginning; there is no partial resume.
- **Names are validated only for exFAT and FAT32.** NTFS uses the extension's own name mapping. Dates and
  permissions are applied through `FileManager`; folder dates and permissions are best effort.
- **A planner abort on an unreadable subfolder** and files of unknown type (`.other`) are not reported item by item.
- **Case-insensitive match** of "drop onto the folder items are already in" is only tested on APFS; exFAT and NTFS
  volumes are not verified.
- **Protection is by path.** Delete and Rename refuse volume roots, top-level system folders and the home folder;
  they do not look at file flags or permissions beyond what macOS enforces.
- **Large lists.** The panel recomputes its visible list on each (throttled) update, which is one pass over all
  items; very large copies (hundreds of thousands of files) are untested.
- **Notification wording** and Dock bounce depend on the user's notification settings.

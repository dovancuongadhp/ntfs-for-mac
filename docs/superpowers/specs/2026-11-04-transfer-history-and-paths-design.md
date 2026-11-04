# File Transfer: copy history and From/To columns

Approved 2026-11-04.

## History

- Starting a copy after the previous one finished keeps the earlier items (`TransferQueue.history`,
  newest copy first) instead of discarding them. They stay until Clear or until the app quits; nothing is
  written to disk.
- `progress` (headline, bar, sizes, speed, time left, summary) covers the latest copy only.
- The list shows the latest copy, then the history. The All / Copying / Errors filters cover both.
- `failedCount`, `failedItems`, Retry Failed and Export Error List cover both. Retrying moves earlier
  failures out of the history into the latest copy.
- Clear empties both; it is offered only when nothing is running.

## Columns

- The list is a table: Name (with state icon and failure reason), From (source folder), To (destination
  folder), Size, Status. Paths are cut at the front and shown whole on hover. Cells are Equatable so a
  progress tick redraws only changed rows.

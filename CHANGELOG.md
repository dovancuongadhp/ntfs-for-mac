# Changelog

All notable changes to NTFS for Mac are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-11-03

### Changed

- Right-clicking the menu bar icon now opens the menu too, not just left-clicking.
- Drive usage in the menu is up to date as soon as the menu opens and keeps updating while it stays open.

## [1.0.0] - 2026-11-03

First public release.

### Added

- Read and write NTFS drives in Finder through an Apple FSKit file system extension — no kernel extension,
  no macFUSE, no SIP changes.
- Drives are mounted read-write automatically when plugged in.
- Menu bar app listing NTFS drives with their status and used space, with mount, eject, Show in Finder and a
  per-drive **Allow writing** switch.
- Automatic read-only fallback, with the reason and a fix, when writing would be unsafe: Windows hibernated or
  Fast Startup, unclean journal, volume flagged for checking, write-protected media or a write error.
- **Allow Writing Anyway…** for drives that weren't ejected safely, after a confirmation.
- macOS extended attributes stored natively as NTFS alternate data streams, so no `._` files are created.
- Welcome window that guides you through turning on the file system extension.
- Settings: open at login, language (system, English, Vietnamese) and extension status.
- English and Vietnamese user interface.
- Drag-to-install DMG, and `scripts/build-local.sh` to build an ad hoc signed copy without an Apple Developer account.

[Unreleased]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dovancuongadhp/ntfs-for-mac/releases/tag/v1.0.0

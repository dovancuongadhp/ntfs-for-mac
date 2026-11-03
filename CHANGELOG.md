# Changelog

All notable changes to NTFS for Mac are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Like macOS, every major version is named, here after a flower: 2.x is **Lotus**. Minor and patch updates keep the
name of their major version, and a name is never reused. Versions 1.0.x have no name.

## [Unreleased]

## [2.0.0] Lotus - 2026-11-04

### Added

- Main window in the style of Disk Utility, opened from **Open NTFS for Mac…** in the menu: every connected drive
  with its partitions, details, a capacity bar and a partition map.
- Mount, unmount, eject and Show in Finder for any drive, not only NTFS.
- Format a partition as NTFS, exFAT, FAT32 or APFS, or erase a whole external drive with a new GPT or MBR partition
  table. A summary shows exactly what will be erased and what won't, and the drive's name must be typed to confirm.
  Formatting re-checks the drive right before every step and stops if anything changed.
- Advanced NTFS options: cluster size and full (zero-filling) format.
- Formatting a Mac partition (APFS or Mac OS Extended) as NTFS also changes its partition type, so Windows
  recognizes it.

### Changed

- The menu bar panel is more compact and opens the main window.
- One window instead of three: the welcome guide and the settings window are now a single **Settings** page in the
  main window, and a banner in the window says when the file system extension is turned off.

### Security

- Internal drives, the drive macOS runs from and the drive the app runs from are protected: they are shown, but
  can't be unmounted, ejected or formatted. Disk images can't be formatted either.
- NTFS formatting runs a small helper with administrator rights, which you grant in the standard macOS password
  dialog. Erasing a whole drive as NTFS first creates an exFAT partition, then asks for the password to turn it
  into NTFS; if you cancel the dialog, the drive stays exFAT.

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

[Unreleased]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v1.0.1...v2.0.0
[1.0.1]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/dovancuongadhp/ntfs-for-mac/releases/tag/v1.0.0

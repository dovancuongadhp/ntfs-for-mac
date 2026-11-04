# Developing NTFS for Mac

How NTFS for Mac is built, how to build it yourself and how to contribute. For using the app, see the
[README](README.md). [Tiếng Việt](CONTRIBUTING.vi.md)

## How it works

```
NTFS for Mac.app
├── Contents/MacOS/NTFS for Mac                ← menu bar app and drive manager (SwiftUI)
├── Contents/Helpers/ntfs-format, ntfs-mkfs, libNTFSDiskOpen.dylib    ← NTFS formatting helpers
└── Contents/Extensions/NTFSExtension.appex    ← FSKit file system extension
        └── NTFSCore → libntfs-3g              ← NTFS engine
```

- The **menu bar app** watches for disks with DiskArbitration, recognizes NTFS volumes from their boot
  sector, decides whether a drive can be safely mounted read-write and asks FSKit to mount it with the extension.
- The **FSKit extension** (`ntfsrw`) runs in user space and translates Finder's file operations into calls to
  libntfs-3g, which reads and writes the NTFS structures directly on the block device. macOS extended
  attributes are stored as NTFS alternate data streams, so no `._` files are written.
- **Formatting** uses `diskutil` for exFAT, FAT32, APFS and partition tables. For NTFS, the `ntfs-format` helper
  re-checks the partition, blocks it from being mounted while it works, and opens the removable disk through
  macOS before running ntfs-3g's `mkntfs`. macOS refuses a direct open of that disk, even for an administrator.
  Erasing a whole drive as NTFS first erases it as exFAT with `diskutil`, then converts the partition.
- **File Transfer** (2.2.0, beta) is an in-app copy engine (`Core/Sources/NTFSTransfer`): files are written
  under a temporary name, optionally verified with SHA-256, and renamed when complete.

## Building from source

Requirements: **Xcode 26** or later. [XcodeGen](https://github.com/yonaskolb/XcodeGen) is only needed after
editing `project.yml` (or adding app source files).

ntfs-3g is a git submodule, so clone with it:

```sh
git clone --recursive https://github.com/dovancuongadhp/ntfs-for-mac.git
# or, in an existing clone: git submodule update --init
```

**Without an Apple Developer account**, run `scripts/build-local.sh`. It builds an ad hoc signed app and
`build/NTFS-for-Mac.dmg` that work on your own Mac. Xcode itself refuses to sign the extension without a team,
so use the script rather than building in Xcode.

**With an account**, for debugging in Xcode and for public releases:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM to your Team ID
xcodegen generate                                        # only needed after editing project.yml
open NTFSForMac.xcodeproj                                # build and run the NTFSForMac scheme
```

Copy the built app to `/Applications` before enabling the extension, because macOS only offers extensions from
installed apps. Replacing the app with a differently signed copy unregisters the extension until it is enabled again.

| Command | What it does |
| --- | --- |
| `swift test --package-path Core` | Unit tests for the core packages (libntfs-3g bridge, formatting, file transfer), using generated disk images |
| `xcodebuild -scheme NTFSForMac CODE_SIGNING_ALLOWED=NO test` | App unit tests |
| `scripts/build-local.sh` | Release build and DMG for your own Mac: signed with your free "Apple Development" certificate if present, else ad hoc |
| `scripts/integration-test.sh` | Mounts a scratch NTFS image through the installed extension and checks data survives a remount |
| `scripts/format-integration-test.sh` | Formats scratch disk images only (never a real drive) with the built helper and `diskutil`, and checks the results |
| `scripts/make-dmg.sh [app] [dmg]` | Packages an app into a drag-to-install DMG (defaults to the unsigned Release build) |
| `scripts/release.sh` | Archive, Developer ID signing, notarization, stapling and the final DMG |
| `scripts/unregister-build-copies.sh` | Removes the copies under `build/` from System Settings' extension list (each build adds one). The two scripts above run it; run it yourself after Xcode builds or tests |
| `swift scripts/make-icon.swift` | Regenerates the app icon |

## Project layout

| Path | Contents |
| --- | --- |
| `App/` | Menu bar app and drive manager: disk inventory (DiskArbitration), mounting, formatting, per-drive settings, File Transfer, the main window and its pages |
| `Extension/` | FSKit file system extension (`ntfsrw`) |
| `Core/` | Swift package: vendored ntfs-3g (`CNTFS`), a typed Swift API over it (`NTFSCore`), boot-sector probing (`NTFSProbe`), the NTFS formatting helper (`NTFSFormat`, `ntfs-format`), the copy engine (`NTFSTransfer`) and identifiers shared by the app and extension (`NTFSShared`) |
| `AppTests/` | App unit tests |
| `scripts/` | Build, packaging, release and integration-test scripts |
| `docs/` | Design specs, implementation plans and release notes |

## Versions

Versions are numbered `major.minor.patch`. Like macOS, every major version also has a name, here an English
flower name that is never reused. Minor (new features) and patch (fixes) updates keep the name of their major
version. Each release carries its full version and name, so 2.0.0 and 2.0.1 never look alike:

| | Pattern | Example |
| --- | --- | --- |
| Release title | NTFS for Mac *version* *Name* | NTFS for Mac 2.1.0 Lotus |
| Git tag | v*version* | v2.1.0 |
| Release branch | release-*version*-*name* | release-2.1.0-lotus |

Unnamed versions just drop the name: NTFS for Mac 1.0.1, branch `release-1.0.1`. Betas add `-beta.N` to the
tag (`v2.2.0-beta.1`) and are published as pre-releases.

| Version | Name | Highlights |
| --- | --- | --- |
| 2.x | **Lotus** | Drive manager and formatting, including NTFS; File Transfer (2.2.0) |
| 1.0.x | — | First release: read and write NTFS drives in Finder |

See the [changelog](CHANGELOG.md) for every change.

## Contributing

Contributions are welcome: bug reports, translations, documentation and code.

1. For anything bigger than a small fix, please open an issue first so we can agree on the approach.
2. Fork the repository and create a branch from `main`.
3. Run the unit tests (`swift test --package-path Core` and the app tests above) and, if you changed the
   extension, `scripts/integration-test.sh`.
4. Open a pull request describing what changed and how you tested it.

To add or improve a translation, edit `App/Localizable.xcstrings` in Xcode.

## Acknowledgements

- [ntfs-3g](https://github.com/tuxera/ntfs-3g) by Tuxera and its contributors, the NTFS engine behind this app.
- Apple's [FSKit](https://developer.apple.com/documentation/fskit), which makes user-space file systems on macOS possible.

## License

NTFS for Mac is free software released under the **GNU General Public License v2.0 or later**, the same license
as ntfs-3g. See [LICENSE](LICENSE).

# File Transfer (Beta) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **File Transfer (Beta)** page to the main window: two file browsers side by side, drag-and-drop or Copy between them, and a progress panel with speeds, per-file status, errors, pause/resume/retry, and a completion notification.

**Architecture:** All logic that can be tested without UI lives in a new SwiftPM target `NTFSTransfer` (`Core/Sources/NTFSTransfer`, tests in `Core/Tests/NTFSTransferTests`, run with `swift test`). It has the copy engine, planner, preflight, progress aggregation, an observable `TransferQueue`, and the folder browser model. The app target adds a thin `TransferSession` plus SwiftUI views under `App/Transfer`. New app files are added to the Xcode project with `scripts/xcode-add.py` because `xcodegen` is not installed.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI on macOS 26, swift-testing, CryptoKit (SHA-256), POSIX file calls, Observation.

**Spec:** `docs/superpowers/specs/2026-11-04-file-transfer-design.md`

## Global Constraints

- Target macOS 26+; Swift language mode 6 (strict concurrency) in `Core`, `App` follows the existing project settings.
- The page is marked **Beta**: a `BETA` capsule in the sidebar row and next to the page title, plus a dismissible first-run notice. The word "Beta" is not translated.
- Copy only; **no Move** in this version. No resume after quitting the app.
- Two panes, any volume or Mac folder in either pane. Below 900 pt the panes stack vertically.
- Pause/Resume, Skip this file, Cancel, Retry failed, and an optional "Ask what to do on errors" prompt (Skip / Retry / Stop with "Apply to all").
- Name conflicts: Replace / Keep Both / Skip / Replace If Newer, with "Apply to all".
- Optional **Verify after copy** (SHA-256 of source versus destination). Default off.
- Copy by 4 MB chunks into `.<name>.ntfs-part`, then rename; the original is never modified. Symbolic links stay links. No extended attributes or resource forks are copied, so no `._name` files appear.
- Deviation from the spec: name validation (`: * ? " < > \ |`, trailing space or dot, DOS names) applies only to **exFAT and FAT32** destinations. The NTFS file system extension already stores such names in a form Windows accepts (2.0.2), so NTFS destinations are not blocked.
- Deviation from the spec: dates and permissions are copied with `FileManager.setAttributes`, not `copyfile`.
- Drive removed mid-file: the current file restarts from the beginning on Resume. A user Pause keeps the file open and continues from the same byte.
- Strings are English in code and Vietnamese in `App/Localizable.xcstrings`. Files copied: counts are written as "Files copied: N" to avoid plural forms.
- Commit after every task. Branch: `release-2.2.0-lotus` (already created). Commit messages end with `Co-authored-by: Cursor <cursoragent@cursor.com>`.
- Test commands: `swift test --package-path Core --filter NTFSTransferTests` for the package; `xcodebuild -scheme NTFSForMac -only-testing:NTFSForMacTests CODE_SIGNING_ALLOWED=NO test` for the app.

## File Structure

| File | Responsibility |
| --- | --- |
| `Core/Package.swift` (modify) | Adds the `NTFSTransfer` library target and the `NTFSTransferTests` test target |
| `Core/Sources/NTFSTransfer/TransferModels.swift` | `FileKind`, `FileAttributes`, `TransferJob`, `TransferFailureReason`, `TransferFailure` (with errno classification) |
| `Core/Sources/NTFSTransfer/FileAccess.swift` | `FileAccess` protocol, `FileReading`, `FileWriting`, `VolumeInfo`, `PosixFileAccess` |
| `Core/Sources/NTFSTransfer/TransferPlanner.swift` | Expands sources into ordered jobs; `UniqueName` |
| `Core/Sources/NTFSTransfer/TransferPreflight.swift` | `DestinationRules`, `WindowsNames`, `TransferProblem`, `TransferPreflight` |
| `Core/Sources/NTFSTransfer/TransferControl.swift` | Thread-safe pause, cancel, skip flags |
| `Core/Sources/NTFSTransfer/TransferEngine.swift` | Options, prompts, events, outcome, `RateMeter`, and the engine itself |
| `Core/Sources/NTFSTransfer/TransferProgress.swift` | `TransferItem`, `TransferProgress`, `TransferSummary` |
| `Core/Sources/NTFSTransfer/TransferQueue.swift` | `@Observable` queue driving the engine, prompts as requests |
| `Core/Sources/NTFSTransfer/FileBrowser.swift` | `FileEntry`, sorting, `DirectoryLister`, `FileBrowserModel`, `Locations`, `FileOperations` |
| `Core/Tests/NTFSTransferTests/*.swift` | Tests for each of the above plus `Fixtures.swift` |
| `scripts/xcode-add.py` (create) | Adds Swift files and package products to the Xcode project |
| `App/Transfer/TransferText.swift` | Localized text for failures, problems, summaries, sizes, rates |
| `App/Transfer/TransferSession.swift` | App-level owner: queue, two panes, prompts, file operations, notifications, sleep, Dock badge |
| `App/Transfer/FilePaneView.swift` | One browser pane |
| `App/Transfer/TransferPage.swift` | The page: header, Beta notice, panes, progress panel, sheets and alerts |
| `App/Transfer/TransferProgressPanel.swift` | Progress panel |
| `App/Transfer/TransferPrompts.swift` | Conflict and error sheets |
| `AppTests/TransferTextTests.swift` | Tests for `TransferText` |
| `App/AppModel.swift`, `App/NTFSForMacApp.swift`, `App/Views/Main/{SidebarView,MainWindowView,Components}.swift`, `App/Views/MenuContentView.swift`, `App/Localizable.xcstrings`, `CHANGELOG.md`, `Config/Base.xcconfig` (modify) | Wiring, Beta badge, strings, version |

---

### Task 1: Package target and the Xcode project script

**Files:**
- Modify: `Core/Package.swift`
- Create: `Core/Sources/NTFSTransfer/TransferModels.swift`
- Create: `Core/Tests/NTFSTransferTests/TransferFailureTests.swift`
- Create: `scripts/xcode-add.py`

**Interfaces:**
- Produces: `FileKind`, `FileAttributes`, `TransferJob`, `TransferFailureReason`, `TransferFailure` (used by every later task); `scripts/xcode-add.py file|product` (used in Task 9 and later).

- [ ] **Step 1: Add the targets to `Core/Package.swift`**

In `products`, after the `NTFSFormat` library line, add:

```swift
        .library(name: "NTFSTransfer", targets: ["NTFSTransfer"]),
```

In `targets`, after `.target(name: "NTFSFormat"),` add:

```swift
        .target(name: "NTFSTransfer"),
        .testTarget(name: "NTFSTransferTests", dependencies: ["NTFSTransfer"]),
```

- [ ] **Step 2: Write the failing test** — `Core/Tests/NTFSTransferTests/TransferFailureTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferFailureTests {
    @Test func outOfSpaceStopsTheWholeTransfer() {
        let failure = TransferFailure.classify(POSIXError(.ENOSPC), reading: false)
        #expect(failure.reason == .noSpace)
        #expect(failure.reason.stopsTransfer)
    }

    @Test func ioErrorWhileReadingMeansADamagedFile() {
        let failure = TransferFailure.classify(POSIXError(.EIO), reading: true)
        #expect(failure.reason == .unreadable)
        #expect(!failure.reason.stopsTransfer)
    }

    @Test func ioErrorWhileWritingIsAWriteFailure() {
        #expect(TransferFailure.classify(POSIXError(.EIO), reading: false).reason == .writeFailed)
    }

    @Test func aMissingDeviceMeansTheDriveWasRemoved() {
        let failure = TransferFailure.classify(POSIXError(.ENXIO), reading: true)
        #expect(failure.reason == .driveRemoved)
        #expect(failure.reason.stopsTransfer)
    }

    @Test func permissionErrors() {
        #expect(TransferFailure.classify(POSIXError(.EACCES), reading: true).reason == .permissionDenied)
        #expect(TransferFailure.classify(POSIXError(.EROFS), reading: false).reason == .permissionDenied)
    }

    @Test func badNamesAreInvalidNames() {
        #expect(TransferFailure.classify(POSIXError(.EILSEQ), reading: false).reason == .invalidName)
        #expect(TransferFailure.classify(POSIXError(.ENAMETOOLONG), reading: false).reason == .invalidName)
    }

    @Test func aMissingSourceFile() {
        #expect(TransferFailure.classify(POSIXError(.ENOENT), reading: true).reason == .sourceMissing)
    }

    @Test func foundationErrorsWrappingPOSIXAreRecognised() {
        let plain = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(TransferFailure.classify(plain, reading: false).reason == .noSpace)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: plain])
        #expect(TransferFailure.classify(wrapped, reading: false).reason == .noSpace)
    }

    @Test func unknownErrorsFallBackByDirection() {
        struct Odd: Error {}
        #expect(TransferFailure.classify(Odd(), reading: true).reason == .unreadable)
        #expect(TransferFailure.classify(Odd(), reading: false).reason == .writeFailed)
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `swift test --package-path Core --filter NTFSTransferTests`
Expected: build error `cannot find 'TransferFailure' in scope` (the target has no sources yet, so also `no sources` is acceptable).

- [ ] **Step 4: Implement** — `Core/Sources/NTFSTransfer/TransferModels.swift`

```swift
import Foundation

public enum FileKind: Sendable, Equatable {
    case file, directory, symlink, other
}

public struct FileAttributes: Sendable, Equatable {
    public var kind: FileKind
    public var size: Int64
    public var modified: Date

    public init(kind: FileKind, size: Int64 = 0, modified: Date = .distantPast) {
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// One thing to create at the destination: a folder, a file or a symbolic link.
public struct TransferJob: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case directory
        case file
        case symlink(target: String)
    }

    public var id: Int
    public var kind: Kind
    public var source: URL
    public var destination: URL
    public var size: Int64
    public var modified: Date

    public init(id: Int, kind: Kind, source: URL, destination: URL, size: Int64 = 0, modified: Date = .distantPast) {
        self.id = id
        self.kind = kind
        self.source = source
        self.destination = destination
        self.size = size
        self.modified = modified
    }

    public var name: String { destination.lastPathComponent }
    public var isDirectory: Bool { kind == .directory }
}

public enum TransferFailureReason: Sendable, Equatable {
    case unreadable
    case writeFailed
    case noSpace
    case driveRemoved
    case permissionDenied
    case invalidName
    case checksumMismatch
    case sizeMismatch
    case sourceMissing
    case conflictingKind

    /// These end the whole run, not just the file they happened on.
    public var stopsTransfer: Bool { self == .noSpace || self == .driveRemoved }
}

public struct TransferFailure: Error, Sendable, Equatable {
    public var reason: TransferFailureReason
    /// The system's own words, for the error list. Not meant for the main message.
    public var detail: String

    public init(_ reason: TransferFailureReason, detail: String = "") {
        self.reason = reason
        self.detail = detail
    }

    /// Turns an error thrown by a read or a write into a reason the user can act on.
    public static func classify(_ error: any Error, reading: Bool) -> TransferFailure {
        let detail = error.localizedDescription
        let fallback: TransferFailureReason = reading ? .unreadable : .writeFailed
        guard let code = errnoCode(of: error) else { return TransferFailure(fallback, detail: detail) }
        switch code {
        case ENOSPC, EDQUOT: return TransferFailure(.noSpace, detail: detail)
        case ENXIO, ENODEV, ENOTCONN, ESTALE: return TransferFailure(.driveRemoved, detail: detail)
        case EACCES, EPERM, EROFS: return TransferFailure(.permissionDenied, detail: detail)
        case EILSEQ, ENAMETOOLONG: return TransferFailure(.invalidName, detail: detail)
        case ENOENT where reading: return TransferFailure(.sourceMissing, detail: detail)
        default: return TransferFailure(fallback, detail: detail)
        }
    }

    private static func errnoCode(of error: any Error) -> Int32? {
        if let posix = error as? POSIXError { return posix.code.rawValue }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }
}
```

- [ ] **Step 5: Create the Xcode project script** — `scripts/xcode-add.py` (then `chmod +x scripts/xcode-add.py`). This exact script was run against a copy of the project and the app built afterwards.

```python
#!/usr/bin/env python3
"""Adds files and package products to NTFSForMac.xcodeproj, standing in for xcodegen.

  scripts/xcode-add.py file App/Transfer/TransferSession.swift [more files...]
  scripts/xcode-add.py file AppTests/TransferTextTests.swift
  scripts/xcode-add.py product NTFSTransfer

Files under App/ go to the NTFSForMac target, files under AppTests/ to NTFSForMacTests.
`product` links a product of the local Core package into the NTFSForMac target.
Running a command twice changes nothing.
"""
import hashlib
import pathlib
import re
import sys

PROJECT = pathlib.Path(__file__).resolve().parent.parent / "NTFSForMac.xcodeproj" / "project.pbxproj"
TARGETS = {"App": "NTFSForMac", "AppTests": "NTFSForMacTests"}
GROUP = re.compile(
    r"\t\t(?P<id>[0-9A-F]{24}) /\* (?P<name>[^\n]*?) \*/ = \{\n\t\t\tisa = PBXGroup;\n"
    r"\t\t\tchildren = \(\n(?P<children>.*?)\t\t\t\);\n(?P<rest>.*?)\t\t\};\n",
    re.S,
)


def ident(seed):
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def append_to_section(text, section, block):
    marker = f"/* End {section} section */"
    at = text.index(marker)
    return text[:at] + block + text[at:]


def groups(text):
    return list(GROUP.finditer(text))


def append_to_list(text, start_pattern, line):
    """Adds `line` as the last entry of the parenthesised list that follows `start_pattern`."""
    match = re.search(start_pattern + r"(?P<items>.*?)\t\t\t\);\n", text, re.S)
    if not match:
        raise SystemExit(f"list not found: {start_pattern}")
    at = match.end("items")
    return text[:at] + line + text[at:]


def find_group(text, parent_id, path):
    for match in groups(text):
        if f"path = {path};" not in match["rest"]:
            continue
        if parent_id is None or match["id"] in parent_children(text, parent_id):
            return match["id"]
    return None


def parent_children(text, group_id):
    match = next(m for m in groups(text) if m["id"] == group_id)
    return match["children"]


def ensure_group(text, directory):
    """Returns the id of the group for `directory` (like App/Transfer), creating missing ones."""
    parent = None
    walked = []
    for part in directory.split("/"):
        walked.append(part)
        found = find_group(text, parent, part)
        if found is None:
            if parent is None:
                raise SystemExit(f"no top-level group for {part}")
            found = ident("group:" + "/".join(walked))
            block = (
                f"\t\t{found} /* {part} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n"
                f'\t\t\tpath = {part};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n'
            )
            text = append_to_section(text, "PBXGroup", block)
            text = add_group_child(text, parent, f"\t\t\t\t{found} /* {part} */,\n")
        parent = found
    return text, parent


def add_group_child(text, group_id, line):
    match = next(m for m in groups(text) if m["id"] == group_id)
    at = match.start("children") + len(match["children"])
    return text[:at] + line + text[at:]


def target_body(text, target):
    pattern = re.compile(r"\t\t[0-9A-F]{24} /\* [^\n]*? \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n(?P<body>.*?)\n\t\t\};\n", re.S)
    for match in pattern.finditer(text):
        if f"name = {target};" in match["body"]:
            return match
    raise SystemExit(f"target not found: {target}")


def phase_id(text, target, phase):
    body = target_body(text, target)["body"]
    found = re.search(rf"([0-9A-F]{{24}}) /\* {phase} \*/", body)
    if not found:
        raise SystemExit(f"{phase} phase not found in {target}")
    return found.group(1)


def add_file(text, relative):
    path = pathlib.PurePosixPath(relative)
    name = path.name
    if re.search(rf"/\* {re.escape(name)} \*/ = \{{isa = PBXFileReference", text):
        return text
    target = TARGETS[path.parts[0]]
    ref, build = ident("ref:" + relative), ident("build:" + relative)
    text = append_to_section(
        text, "PBXBuildFile",
        f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n")
    text = append_to_section(
        text, "PBXFileReference",
        f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f'path = {name}; sourceTree = "<group>"; }};\n')
    text, group = ensure_group(text, str(path.parent))
    text = add_group_child(text, group, f"\t\t\t\t{ref} /* {name} */,\n")
    sources = phase_id(text, target, "Sources")
    return append_to_list(
        text, rf"{sources} /\* Sources \*/ = \{{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n",
        f"\t\t\t\t{build} /* {name} in Sources */,\n")


def add_product(text, product):
    if f"productName = {product};" in text:
        return text
    target = "NTFSForMac"
    ref, build = ident("product:" + product), ident("productbuild:" + product)
    text = append_to_section(
        text, "PBXBuildFile",
        f"\t\t{build} /* {product} in Frameworks */ = {{isa = PBXBuildFile; productRef = {ref} /* {product} */; }};\n")
    text = append_to_section(
        text, "XCSwiftPackageProductDependency",
        f"\t\t{ref} /* {product} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {product};\n\t\t}};\n")
    frameworks = phase_id(text, target, "Frameworks")
    text = append_to_list(
        text, rf"{frameworks} /\* Frameworks \*/ = \{{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n",
        f"\t\t\t\t{build} /* {product} in Frameworks */,\n")
    body = target_body(text, target)
    start = body.start("body")
    inner = text[start:body.end("body")]
    marker = "packageProductDependencies = (\n"
    at = start + inner.index(marker) + len(marker)
    end = text.index("\t\t\t);", at)
    return text[:end] + f"\t\t\t\t{ref} /* {product} */,\n" + text[end:]


def main(arguments):
    if len(arguments) < 2 or arguments[0] not in ("file", "product"):
        raise SystemExit(__doc__)
    text = PROJECT.read_text()
    for item in arguments[1:]:
        text = add_file(text, item) if arguments[0] == "file" else add_product(text, item)
    PROJECT.write_text(text)


main(sys.argv[1:])
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path Core --filter NTFSTransferTests`
Expected: 9 tests in `TransferFailureTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Core/Package.swift Core/Sources/NTFSTransfer Core/Tests/NTFSTransferTests scripts/xcode-add.py
git commit -m "Add the NTFSTransfer package target, failure classification and the Xcode file script." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 2: File access (POSIX) and test fixtures

**Files:**
- Create: `Core/Sources/NTFSTransfer/FileAccess.swift`
- Create: `Core/Tests/NTFSTransferTests/Fixtures.swift`
- Create: `Core/Tests/NTFSTransferTests/PosixFileAccessTests.swift`

**Interfaces:**
- Consumes: `FileAttributes`, `FileKind` (Task 1).
- Produces: `FileReading`, `FileWriting`, `FileAccess` (`attributes(of:)`, `children(of:)`, `exists(_:)`, `makeDirectory(_:)`, `readLink(_:)`, `makeLink(at:target:)`, `openForReading(_:)`, `createForWriting(_:)`, `rename(_:to:)`, `remove(_:)`, `copyMetadata(from:to:)`, `volumeInfo(at:)`), `VolumeInfo`, `PosixFileAccess`; test helpers `TempFolder`, `EventLog`, `Flaky`, `plan(...)`, `run(...)`.

- [ ] **Step 1: Write the test fixture** — `Core/Tests/NTFSTransferTests/Fixtures.swift`. Task 5 adds more helpers to this file.

```swift
import Darwin
import Foundation
@testable import NTFSTransfer

/// A throwaway folder, removed when the test ends.
final class TempFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(component: "ntfs-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> URL { url.appending(path: relative) }

    @discardableResult
    func file(_ relative: String, _ text: String = "x") throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }

    @discardableResult
    func data(_ relative: String, count: Int) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        try Data(bytes).write(to: target)
        return target
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func text(_ relative: String) throws -> String {
        String(decoding: try Data(contentsOf: path(relative)), as: UTF8.self)
    }

    func has(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative).path, &info) == 0
    }

    /// Names of everything directly inside `relative`, sorted.
    func names(_ relative: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(relative).path).sorted()
    }

    func setModified(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative).path)
    }
}
```

- [ ] **Step 2: Write the failing tests** — `Core/Tests/NTFSTransferTests/PosixFileAccessTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct PosixFileAccessTests {
    let access = PosixFileAccess()

    @Test func attributesDescribeFilesFoldersAndLinks() throws {
        let folder = try TempFolder()
        let file = try folder.file("a.txt", "hello")
        let sub = try folder.folder("sub")
        let link = folder.path("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")

        #expect(try access.attributes(of: file).kind == .file)
        #expect(try access.attributes(of: file).size == 5)
        #expect(try access.attributes(of: sub).kind == .directory)
        #expect(try access.attributes(of: link).kind == .symlink)
        #expect(try access.readLink(link) == "a.txt")
    }

    @Test func missingFilesThrowAndDoNotExist() throws {
        let folder = try TempFolder()
        #expect(!access.exists(folder.path("nope")))
        #expect(throws: (any Error).self) { try access.attributes(of: folder.path("nope")) }
    }

    @Test func childrenAreSortedByName() throws {
        let folder = try TempFolder()
        try folder.file("b"); try folder.file("a"); try folder.file("c")
        #expect(try access.children(of: folder.url).map(\.lastPathComponent) == ["a", "b", "c"])
    }

    @Test func writingThenReadingRoundTripsInChunks() throws {
        let folder = try TempFolder()
        let target = folder.path("out.bin")
        let payload = Data((0..<2500).map { UInt8(truncatingIfNeeded: $0) })
        let writer = try access.createForWriting(target)
        try writer.write(payload.prefix(1000))
        try writer.write(payload.suffix(from: 1000))
        try writer.sync()
        try writer.close()

        let reader = try access.openForReading(target)
        var collected = Data()
        while true {
            let chunk = try reader.read(upTo: 1024)
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
        reader.close()
        #expect(collected == payload)
    }

    @Test func emptyFilesReadAsEmpty() throws {
        let folder = try TempFolder()
        let reader = try access.openForReading(try folder.file("empty", ""))
        #expect(try reader.read(upTo: 10).isEmpty)
        reader.close()
    }

    @Test func renameReplacesAnExistingFile() throws {
        let folder = try TempFolder()
        let from = try folder.file("new", "new")
        let to = try folder.file("old", "old")
        try access.rename(from, to: to)
        #expect(try folder.text("old") == "new")
        #expect(!folder.has("new"))
    }

    @Test func removeDeletesFilesAndFolders() throws {
        let folder = try TempFolder()
        try folder.file("d/f")
        try access.remove(folder.path("d"))
        #expect(!folder.has("d"))
    }

    @Test func copyMetadataKeepsTheModificationDate() throws {
        let folder = try TempFolder()
        let from = try folder.file("a")
        let to = try folder.file("b")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try folder.setModified("a", date)
        access.copyMetadata(from: from, to: to)
        #expect(abs(try access.attributes(of: to).modified.timeIntervalSince(date)) < 1)
    }

    @Test func volumeInfoReportsTheFileSystemAndFreeSpace() throws {
        let folder = try TempFolder()
        let info = try access.volumeInfo(at: folder.url)
        #expect(!info.fileSystemType.isEmpty)
        #expect(info.freeBytes > 0)
    }

    @Test func makeLinkCreatesASymbolicLink() throws {
        let folder = try TempFolder()
        try access.makeLink(at: folder.path("l"), target: "somewhere")
        #expect(try access.readLink(folder.path("l")) == "somewhere")
    }
}
```

- [ ] **Step 3: Run to see it fail**

Run: `swift test --package-path Core --filter PosixFileAccessTests`
Expected: `cannot find 'PosixFileAccess' in scope`.

- [ ] **Step 4: Implement** — `Core/Sources/NTFSTransfer/FileAccess.swift`

```swift
import Darwin
import Foundation

public protocol FileReading: AnyObject, Sendable {
    /// Returns up to `count` bytes, or empty data at the end of the file.
    func read(upTo count: Int) throws -> Data
    func close()
}

public protocol FileWriting: AnyObject, Sendable {
    func write(_ data: Data) throws
    func sync() throws
    func close() throws
}

public struct VolumeInfo: Sendable, Equatable {
    public var fileSystemType: String
    public var freeBytes: Int64

    public init(fileSystemType: String, freeBytes: Int64) {
        self.fileSystemType = fileSystemType
        self.freeBytes = freeBytes
    }
}

/// Everything the engine needs from a file system. Tests wrap the real one to inject failures.
public protocol FileAccess: Sendable {
    func attributes(of url: URL) throws -> FileAttributes
    func children(of url: URL) throws -> [URL]
    func exists(_ url: URL) -> Bool
    func makeDirectory(_ url: URL) throws
    func readLink(_ url: URL) throws -> String
    func makeLink(at url: URL, target: String) throws
    func openForReading(_ url: URL) throws -> any FileReading
    func createForWriting(_ url: URL) throws -> any FileWriting
    /// Renames, replacing a file already at `to`.
    func rename(_ from: URL, to: URL) throws
    func remove(_ url: URL) throws
    /// Best effort: dates and permissions the destination may refuse are ignored.
    func copyMetadata(from: URL, to: URL)
    func volumeInfo(at url: URL) throws -> VolumeInfo
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

public struct PosixFileAccess: FileAccess {
    public init() {}

    public func attributes(of url: URL) throws -> FileAttributes {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        let kind: FileKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileAttributes(kind: kind, size: Int64(info.st_size), modified: Date(timeIntervalSince1970: seconds))
    }

    public func children(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().map { url.appending(component: $0) }
    }

    public func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public func makeDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o777) == 0 else { throw posixError() }
    }

    public func readLink(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public func makeLink(at url: URL, target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    public func openForReading(_ url: URL) throws -> any FileReading {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        // Skip the page cache so speeds reflect the drive and a checksum reads what was stored.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return PosixReader(descriptor: descriptor)
    }

    public func createForWriting(_ url: URL) throws -> any FileWriting {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard descriptor >= 0 else { throw posixError() }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return PosixWriter(descriptor: descriptor)
    }

    public func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else { throw posixError() }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func copyMetadata(from: URL, to: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: from.path) else { return }
        var wanted: [FileAttributeKey: Any] = [:]
        if let date = attributes[.modificationDate] { wanted[.modificationDate] = date }
        if let permissions = attributes[.posixPermissions] { wanted[.posixPermissions] = permissions }
        try? FileManager.default.setAttributes(wanted, ofItemAtPath: to.path)
    }

    public func volumeInfo(at url: URL) throws -> VolumeInfo {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw posixError() }
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return VolumeInfo(fileSystemType: type, freeBytes: Int64(info.f_bavail) * Int64(info.f_bsize))
    }
}

private final class PosixReader: FileReading, @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }

    func read(upTo count: Int) throws -> Data {
        var data = Data(count: count)
        while true {
            let descriptor = descriptor
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
            if received < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            data.removeSubrange(received..<data.count)
            return data
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

private final class PosixWriter: FileWriting, @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let descriptor = descriptor
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
    }

    func sync() throws {
        if fsync(descriptor) != 0, errno != ENOTSUP, errno != EINVAL { throw posixError() }
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let result = Darwin.close(descriptor)
        let code = errno
        descriptor = -1
        if result != 0, code != EINTR { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Core --filter PosixFileAccessTests`
Expected: 10 tests pass. If `TempFolder.has` fails to compile because `stat()`/`lstat` need `import Darwin`, add `import Darwin` at the top of `Fixtures.swift`.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/NTFSTransfer/FileAccess.swift Core/Tests/NTFSTransferTests
git commit -m "Add POSIX file access for the transfer engine." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 3: Planner, unique names, preflight

**Files:**
- Create: `Core/Sources/NTFSTransfer/TransferPlanner.swift`
- Create: `Core/Sources/NTFSTransfer/TransferPreflight.swift`
- Create: `Core/Tests/NTFSTransferTests/TransferPlannerTests.swift`
- Create: `Core/Tests/NTFSTransferTests/TransferPreflightTests.swift`

**Interfaces:**
- Consumes: `FileAccess`, `TransferJob` (Tasks 1–2).
- Produces: `TransferPlanner.plan(sources:into:access:) throws -> [TransferJob]`, `TransferPlanner.PlanError.destinationInsideSource(String)`, `UniqueName.make(for:exists:) -> URL`, `DestinationRules` (`rejectsWindowsNames`, `maxFileSize`, `.unrestricted`, `.exFAT`, `.fat32`, `forFileSystem(_:)`), `WindowsNames.isValid(_:)`, `TransferProblem` (`.notEnoughSpace(needed:available:)`, `.invalidName(job:name:)`, `.fileTooLarge(job:name:)`, `isBlocking`, `jobID`), `TransferPreflight.check(jobs:rules:freeBytes:)`, `TransferPreflight.jobs(_:without:)`.

- [ ] **Step 1: Write the failing tests** — `TransferPlannerTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferPlannerTests {
    @Test func foldersComeBeforeTheirContentsAndIdsAreSequential() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("tree/a.txt", "12345")
        try source.file("tree/sub/b.txt", "1")
        let jobs = try plan([source.path("tree")], into: destination.url)

        #expect(jobs.map(\.id) == [0, 1, 2, 3])
        #expect(jobs.map(\.name) == ["tree", "a.txt", "sub", "b.txt"])
        #expect(jobs.map(\.isDirectory) == [true, false, true, false])
        #expect(jobs[1].size == 5)
        #expect(jobs[1].destination == destination.path("tree/a.txt"))
    }

    @Test func aSingleFileIsOneJob() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let jobs = try plan([try source.file("one.txt")], into: destination.url)
        #expect(jobs.count == 1)
        #expect(jobs[0].kind == .file)
    }

    @Test func symbolicLinksStayLinks() throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("real.txt")
        try FileManager.default.createSymbolicLink(atPath: source.path("link").path, withDestinationPath: "real.txt")
        let jobs = try plan([source.path("link")], into: destination.url)
        #expect(jobs.map(\.kind) == [.symlink(target: "real.txt")])
    }

    @Test func aFolderCannotGoIntoItselfOrBelowItself() throws {
        let source = try TempFolder()
        try source.folder("a/b")
        #expect(throws: TransferPlanner.PlanError.destinationInsideSource("a")) {
            try plan([source.path("a")], into: source.path("a"))
        }
        #expect(throws: TransferPlanner.PlanError.destinationInsideSource("a")) {
            try plan([source.path("a")], into: source.path("a/b"))
        }
    }

    @Test func aFileMayBeCopiedIntoItsOwnFolder() throws {
        let source = try TempFolder()
        let file = try source.file("a.txt")
        let jobs = try plan([file], into: source.url)
        #expect(jobs.count == 1)
    }

    @Test func uniqueNameAddsANumberBeforeTheExtension() {
        let taken: Set<String> = ["/x/a 2.txt", "/x/a 3.txt"]
        let url = UniqueName.make(for: URL(fileURLWithPath: "/x/a.txt")) { taken.contains($0.path) }
        #expect(url.path == "/x/a 4.txt")
    }

    @Test func uniqueNameWorksWithoutAnExtension() {
        let url = UniqueName.make(for: URL(fileURLWithPath: "/x/folder")) { _ in false }
        #expect(url.path == "/x/folder 2")
    }
}
```

`TransferPreflightTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferPreflightTests {
    private func file(_ id: Int, _ name: String, size: Int64) -> TransferJob {
        TransferJob(
            id: id, kind: .file, source: URL(fileURLWithPath: "/s/\(name)"),
            destination: URL(fileURLWithPath: "/d/\(name)"), size: size)
    }

    @Test func windowsNameRules() {
        #expect(WindowsNames.isValid("report.pdf"))
        #expect(!WindowsNames.isValid("a:b.txt"))
        #expect(!WindowsNames.isValid("what?"))
        #expect(!WindowsNames.isValid("trailing."))
        #expect(!WindowsNames.isValid("trailing "))
        #expect(!WindowsNames.isValid("CON"))
        #expect(!WindowsNames.isValid("con.txt"))
        #expect(!WindowsNames.isValid("COM3"))
        #expect(WindowsNames.isValid("CONSOLE.txt"))
        #expect(!WindowsNames.isValid(""))
        #expect(!WindowsNames.isValid("tab\there"))
    }

    @Test func rulesFollowTheFileSystem() {
        #expect(DestinationRules.forFileSystem("exfat") == .exFAT)
        #expect(DestinationRules.forFileSystem("msdos") == .fat32)
        #expect(DestinationRules.forFileSystem("ntfs") == .unrestricted)
        #expect(DestinationRules.forFileSystem("apfs") == .unrestricted)
    }

    @Test func notEnoughSpaceBlocks() {
        let jobs = [file(0, "a", size: 600), file(1, "b", size: 600)]
        let problems = TransferPreflight.check(jobs: jobs, rules: .unrestricted, freeBytes: 1000)
        #expect(problems == [.notEnoughSpace(needed: 1200, available: 1000)])
        #expect(problems[0].isBlocking)
    }

    @Test func exactFitIsFine() {
        let problems = TransferPreflight.check(jobs: [file(0, "a", size: 1000)], rules: .unrestricted, freeBytes: 1000)
        #expect(problems.isEmpty)
    }

    @Test func invalidNamesOnlyMatterOnExFATAndFAT32() {
        let jobs = [file(0, "bad:name.txt", size: 1)]
        #expect(TransferPreflight.check(jobs: jobs, rules: .exFAT, freeBytes: 10) == [.invalidName(job: 0, name: "bad:name.txt")])
        #expect(TransferPreflight.check(jobs: jobs, rules: .unrestricted, freeBytes: 10).isEmpty)
    }

    @Test func fat32RejectsFilesOverFourGigabytes() {
        let big = file(0, "big.iso", size: 4_294_967_296)
        let ok = file(1, "ok.iso", size: 4_294_967_295)
        let problems = TransferPreflight.check(jobs: [big, ok], rules: .fat32, freeBytes: .max)
        #expect(problems == [.fileTooLarge(job: 0, name: "big.iso")])
        #expect(!problems[0].isBlocking)
    }

    @Test func excludingProblemJobsAlsoDropsWhatIsInsideThem() {
        let folder = TransferJob(id: 0, kind: .directory, source: URL(fileURLWithPath: "/s/bad:dir"), destination: URL(fileURLWithPath: "/d/bad:dir"))
        let inside = TransferJob(id: 1, kind: .file, source: URL(fileURLWithPath: "/s/bad:dir/f"), destination: URL(fileURLWithPath: "/d/bad:dir/f"), size: 1)
        let other = file(2, "fine.txt", size: 1)
        let problems: [TransferProblem] = [.invalidName(job: 0, name: "bad:dir")]
        let kept = TransferPreflight.jobs([folder, inside, other], without: problems)
        #expect(kept.map(\.id) == [2])
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path Core --filter "TransferPlannerTests|TransferPreflightTests"`
Expected: `cannot find 'TransferPlanner' in scope`.

- [ ] **Step 3: Implement** — `TransferPlanner.swift`

```swift
import Foundation

public enum TransferPlanner {
    public enum PlanError: Error, Equatable {
        case destinationInsideSource(String)
    }

    /// Lists, in copy order, everything needed to put `sources` inside `folder`.
    public static func plan(sources: [URL], into folder: URL, access: any FileAccess) throws -> [TransferJob] {
        var jobs: [TransferJob] = []
        let target = folder.standardizedFileURL.path
        for source in sources {
            let attributes = try access.attributes(of: source)
            let sourcePath = source.standardizedFileURL.path
            if attributes.kind == .directory, target == sourcePath || target.hasPrefix(sourcePath + "/") {
                throw PlanError.destinationInsideSource(source.lastPathComponent)
            }
            try add(
                source, attributes: attributes,
                destination: folder.appending(component: source.lastPathComponent),
                access: access, jobs: &jobs)
        }
        return jobs
    }

    private static func add(
        _ source: URL, attributes: FileAttributes, destination: URL,
        access: any FileAccess, jobs: inout [TransferJob]
    ) throws {
        func job(_ kind: TransferJob.Kind) -> TransferJob {
            TransferJob(
                id: jobs.count, kind: kind, source: source, destination: destination,
                size: kind == .file ? attributes.size : 0, modified: attributes.modified)
        }
        switch attributes.kind {
        case .directory:
            jobs.append(job(.directory))
            for child in try access.children(of: source) {
                let childAttributes = try access.attributes(of: child)
                try add(
                    child, attributes: childAttributes,
                    destination: destination.appending(component: child.lastPathComponent),
                    access: access, jobs: &jobs)
            }
        case .file:
            jobs.append(job(.file))
        case .symlink:
            jobs.append(job(.symlink(target: try access.readLink(source))))
        case .other:
            break
        }
    }
}

public enum UniqueName {
    /// "a.txt" becomes "a 2.txt", then "a 3.txt", until a name is free.
    public static func make(for url: URL, exists: (URL) -> Bool) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appending(component: name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
}
```

`TransferPreflight.swift`

```swift
import Foundation

public struct DestinationRules: Sendable, Equatable {
    public var rejectsWindowsNames: Bool
    public var maxFileSize: Int64?

    public init(rejectsWindowsNames: Bool, maxFileSize: Int64?) {
        self.rejectsWindowsNames = rejectsWindowsNames
        self.maxFileSize = maxFileSize
    }

    public static let unrestricted = DestinationRules(rejectsWindowsNames: false, maxFileSize: nil)
    public static let exFAT = DestinationRules(rejectsWindowsNames: true, maxFileSize: nil)
    public static let fat32 = DestinationRules(rejectsWindowsNames: true, maxFileSize: 4_294_967_295)

    /// `fileSystemType` is the `f_fstypename` macOS reports. NTFS is unrestricted because the
    /// file system extension stores names Windows rejects in a form Windows accepts.
    public static func forFileSystem(_ fileSystemType: String) -> DestinationRules {
        switch fileSystemType.lowercased() {
        case "exfat": .exFAT
        case "msdos": .fat32
        default: .unrestricted
        }
    }
}

public enum WindowsNames {
    private static let forbidden = Set("\\/:*?\"<>|")
    private static let reserved: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for number in 1...9 {
            names.insert("COM\(number)")
            names.insert("LPT\(number)")
        }
        return names
    }()

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        if name.contains(where: { forbidden.contains($0) || ($0.asciiValue ?? 255) < 32 }) { return false }
        if name.hasSuffix(" ") || name.hasSuffix(".") { return false }
        let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        return !reserved.contains(stem.trimmingCharacters(in: .whitespaces).uppercased())
    }
}

public enum TransferProblem: Sendable, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case invalidName(job: Int, name: String)
    case fileTooLarge(job: Int, name: String)

    /// A blocking problem means nothing should be copied; the others can be skipped.
    public var isBlocking: Bool {
        if case .notEnoughSpace = self { true } else { false }
    }

    public var jobID: Int? {
        switch self {
        case .notEnoughSpace: nil
        case .invalidName(let job, _), .fileTooLarge(let job, _): job
        }
    }
}

public enum TransferPreflight {
    public static func check(jobs: [TransferJob], rules: DestinationRules, freeBytes: Int64) -> [TransferProblem] {
        var problems: [TransferProblem] = []
        let needed = jobs.reduce(Int64(0)) { $0 + ($1.kind == .file ? $1.size : 0) }
        if needed > freeBytes {
            problems.append(.notEnoughSpace(needed: needed, available: freeBytes))
        }
        for job in jobs {
            if rules.rejectsWindowsNames, !WindowsNames.isValid(job.name) {
                problems.append(.invalidName(job: job.id, name: job.name))
            }
            if let limit = rules.maxFileSize, job.kind == .file, job.size > limit {
                problems.append(.fileTooLarge(job: job.id, name: job.name))
            }
        }
        return problems
    }

    /// The jobs left after dropping every job named in `problems` and everything inside it.
    public static func jobs(_ jobs: [TransferJob], without problems: [TransferProblem]) -> [TransferJob] {
        let excluded = Set(problems.compactMap(\.jobID))
        let blocked = jobs.filter { excluded.contains($0.id) }.map { $0.destination.path }
        return jobs.filter { job in
            !blocked.contains { job.destination.path == $0 || job.destination.path.hasPrefix($0 + "/") }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter "TransferPlannerTests|TransferPreflightTests"`
Expected: 7 planner tests and 7 preflight tests pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/NTFSTransfer Core/Tests/NTFSTransferTests
git commit -m "Plan transfers into ordered jobs and check them against the destination first." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 4: Control flags and rate meter

**Files:**
- Create: `Core/Sources/NTFSTransfer/TransferControl.swift`
- Create: `Core/Tests/NTFSTransferTests/TransferControlTests.swift`

**Interfaces:**
- Produces: `TransferControl` (`init()`, `isPaused`, `isCancelled`, `pause()`, `resume()`, `cancel()`, `skipCurrent()`, internal `clearSkip()`, `takeSkip()`, `waitWhilePaused() async`), internal `RateMeter` (`addRead(bytes:seconds:)`, `addWrite(bytes:seconds:)`, `takeRates() -> (read: Double, write: Double)`).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferControlTests {
    @Test func pauseAndResumeToggleTheFlag() {
        let control = TransferControl()
        #expect(!control.isPaused)
        control.pause()
        #expect(control.isPaused)
        control.resume()
        #expect(!control.isPaused)
    }

    @Test func cancelLiftsAPauseSoWaitersWakeUp() {
        let control = TransferControl()
        control.pause()
        control.cancel()
        #expect(control.isCancelled)
        #expect(!control.isPaused)
    }

    @Test func skipIsTakenOnceAndCanBeCleared() {
        let control = TransferControl()
        control.skipCurrent()
        #expect(control.takeSkip())
        #expect(!control.takeSkip())
        control.skipCurrent()
        control.clearSkip()
        #expect(!control.takeSkip())
    }

    @Test func waitingReturnsOnceResumed() async throws {
        let control = TransferControl()
        control.pause()
        let waiter = Task { await control.waitWhilePaused() }
        try await Task.sleep(for: .milliseconds(120))
        control.resume()
        await waiter.value
    }

    @Test func rateMeterReportsBytesPerSecondOfEachSideAndResets() {
        var meter = RateMeter()
        meter.addRead(bytes: 1000, seconds: 0.5)
        meter.addWrite(bytes: 1000, seconds: 0.25)
        let first = meter.takeRates()
        #expect(first.read == 2000)
        #expect(first.write == 4000)
        let second = meter.takeRates()
        #expect(second.read == 0)
        #expect(second.write == 0)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --package-path Core --filter TransferControlTests`
Expected: `cannot find 'TransferControl' in scope`.

- [ ] **Step 3: Implement** — `TransferControl.swift`

```swift
import Foundation
import os

/// Lets the interface pause, skip or cancel an engine that runs on another thread.
public final class TransferControl: Sendable {
    private struct State {
        var paused = false
        var cancelled = false
        var skip = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isPaused: Bool { state.withLock { $0.paused } }
    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func pause() { state.withLock { $0.paused = true } }
    public func resume() { state.withLock { $0.paused = false } }
    public func cancel() { state.withLock { $0.cancelled = true; $0.paused = false } }
    public func skipCurrent() { state.withLock { $0.skip = true } }

    func clearSkip() { state.withLock { $0.skip = false } }

    func takeSkip() -> Bool {
        state.withLock { state in
            let wanted = state.skip
            state.skip = false
            return wanted
        }
    }

    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Measures how fast reading and writing each go, counting only the time spent in those calls.
struct RateMeter {
    private var readBytes = 0
    private var readSeconds = 0.0
    private var writeBytes = 0
    private var writeSeconds = 0.0

    mutating func addRead(bytes: Int, seconds: Double) {
        readBytes += bytes
        readSeconds += seconds
    }

    mutating func addWrite(bytes: Int, seconds: Double) {
        writeBytes += bytes
        writeSeconds += seconds
    }

    /// Bytes per second since the last call; starts a new window.
    mutating func takeRates() -> (read: Double, write: Double) {
        let rates = (
            read: readSeconds > 0 ? Double(readBytes) / readSeconds : 0,
            write: writeSeconds > 0 ? Double(writeBytes) / writeSeconds : 0)
        self = RateMeter()
        return rates
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter TransferControlTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/NTFSTransfer Core/Tests/NTFSTransferTests
git commit -m "Add pause, skip and cancel flags and a read/write rate meter." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 5: The transfer engine

**Files:**
- Create: `Core/Sources/NTFSTransfer/TransferEngine.swift`
- Modify: `Core/Tests/NTFSTransferTests/Fixtures.swift` (append the engine helpers)
- Create: `Core/Tests/NTFSTransferTests/TransferEngineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: `TransferOptions`, `ConflictChoice`, `ConflictDecision`, `ConflictInfo`, `ErrorChoice`, `ErrorDecision`, `ErrorInfo`, `TransferPrompts` (`conflict`, `error`, `.automatic`), `TransferEvent`, `TransferStop`, `TransferOutcome`, `TransferEngine.run(jobs:control:prompts:emit:) async -> TransferOutcome`.

- [ ] **Step 1: Append the engine helpers to `Fixtures.swift`**

Add `import os` to the imports at the top, then append to the end of the file:

```swift
final class EventLog: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [TransferEvent]())
    func add(_ event: TransferEvent) { storage.withLock { $0.append(event) } }
    var events: [TransferEvent] { storage.withLock { $0 } }
}

final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    func increment() { storage.withLock { $0 += 1 } }
    var value: Int { storage.withLock { $0 } }
}

/// The real file system with chosen failures added, keyed by the file's own name.
final class Flaky: FileAccess, @unchecked Sendable {
    struct Rules {
        var failReading: Set<String> = []
        var failWriting: [String: POSIXErrorCode] = [:]
        var corrupt: Set<String> = []
        /// Makes every `exists` answer false, as if the drives were gone.
        var vanished = false
    }

    private let base = PosixFileAccess()
    private let rules = OSAllocatedUnfairLock(initialState: Rules())

    func update(_ change: (inout Rules) -> Void) {
        var copy = rules.withLock { $0 }
        change(&copy)
        let updated = copy
        rules.withLock { $0 = updated }
    }

    private func original(of url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".ntfs-part") {
            name = String(name.dropFirst().dropLast(".ntfs-part".count))
        }
        return name
    }

    func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: url) }
    func children(of url: URL) throws -> [URL] { try base.children(of: url) }
    func exists(_ url: URL) -> Bool { rules.withLock { $0.vanished } ? false : base.exists(url) }
    func makeDirectory(_ url: URL) throws { try base.makeDirectory(url) }
    func readLink(_ url: URL) throws -> String { try base.readLink(url) }
    func makeLink(at url: URL, target: String) throws { try base.makeLink(at: url, target: target) }
    func rename(_ from: URL, to: URL) throws { try base.rename(from, to: to) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func copyMetadata(from: URL, to: URL) { base.copyMetadata(from: from, to: to) }
    func volumeInfo(at url: URL) throws -> VolumeInfo { try base.volumeInfo(at: url) }

    func openForReading(_ url: URL) throws -> any FileReading {
        let reader = try base.openForReading(url)
        let fails = rules.withLock { $0.failReading.contains(original(of: url)) }
        return fails ? FailingReader(wrapping: reader) : reader
    }

    func createForWriting(_ url: URL) throws -> any FileWriting {
        let writer = try base.createForWriting(url)
        let name = original(of: url)
        let rule = rules.withLock { (error: $0.failWriting[name], corrupt: $0.corrupt.contains(name)) }
        return FlakyWriter(wrapping: writer, error: rule.error, corrupt: rule.corrupt)
    }
}

final class FailingReader: FileReading, @unchecked Sendable {
    private let inner: any FileReading
    init(wrapping inner: any FileReading) { self.inner = inner }
    func read(upTo count: Int) throws -> Data { throw POSIXError(.EIO) }
    func close() { inner.close() }
}

final class FlakyWriter: FileWriting, @unchecked Sendable {
    private let inner: any FileWriting
    private let error: POSIXErrorCode?
    private let corrupt: Bool

    init(wrapping inner: any FileWriting, error: POSIXErrorCode?, corrupt: Bool) {
        self.inner = inner
        self.error = error
        self.corrupt = corrupt
    }

    func write(_ data: Data) throws {
        if let error { throw POSIXError(error) }
        guard corrupt, !data.isEmpty else { return try inner.write(data) }
        var changed = data
        changed[0] ^= 0xFF
        try inner.write(changed)
    }

    func sync() throws { try inner.sync() }
    func close() throws { try inner.close() }
}

struct EngineRun {
    var outcome: TransferOutcome
    var events: [TransferEvent]
}

func plan(_ sources: [URL], into folder: URL) throws -> [TransferJob] {
    try TransferPlanner.plan(sources: sources, into: folder, access: PosixFileAccess())
}

func run(
    _ jobs: [TransferJob],
    access: any FileAccess = PosixFileAccess(),
    verify: Bool = false,
    askOnError: Bool = false,
    chunk: Int = 1024,
    control: TransferControl = TransferControl(),
    prompts: TransferPrompts = .automatic,
    onEvent: (@Sendable (TransferEvent) -> Void)? = nil
) async -> EngineRun {
    let log = EventLog()
    let engine = TransferEngine(
        access: access,
        options: TransferOptions(verify: verify, askOnError: askOnError, chunkSize: chunk, progressInterval: .zero))
    let outcome = await engine.run(jobs: jobs, control: control, prompts: prompts) { event in
        log.add(event)
        onEvent?(event)
    }
    return EngineRun(outcome: outcome, events: log.events)
}
```

- [ ] **Step 2: Write the failing tests** — `TransferEngineTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferEngineTests {
    private func choosing(_ choice: ConflictChoice, applyToAll: Bool = false, counter: Counter? = nil) -> TransferPrompts {
        TransferPrompts(
            conflict: { _ in
                counter?.increment()
                return ConflictDecision(choice: choice, applyToAll: applyToAll)
            },
            error: { _ in ErrorDecision(choice: .skip) })
    }

    // MARK: Copying

    @Test func copiesFilesAndFoldersWithTheirContents() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("tree/a.txt", "alpha")
        try source.file("tree/sub/b.txt", "beta")
        try source.file("tree/empty.txt", "")
        let jobs = try plan([source.path("tree")], into: destination.url)

        let result = await run(jobs)

        #expect(result.outcome.stop == .finished)
        #expect(result.outcome.copied == 3)
        #expect(result.outcome.failed == 0)
        #expect(try destination.text("tree/a.txt") == "alpha")
        #expect(try destination.text("tree/sub/b.txt") == "beta")
        #expect(destination.has("tree/empty.txt"))
        let finished = result.events.filter { if case .finished = $0 { true } else { false } }
        #expect(finished.count == jobs.count)
    }

    @Test func aFileLargerThanOneChunkIsCopiedExactly() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let original = try source.data("big.bin", count: 3_000_000)
        let jobs = try plan([original], into: destination.url)

        let result = await run(jobs, chunk: 1_000_000)

        #expect(result.outcome.bytes == 3_000_000)
        #expect(try Data(contentsOf: destination.path("big.bin")) == Data(contentsOf: original))
    }

    @Test func noTemporaryFilesAreLeftBehind() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        _ = await run(try plan([source.path("a.txt")], into: destination.url))
        #expect(try destination.names() == ["a.txt"])
    }

    @Test func progressEventsCarryBytesAndRates() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        let original = try source.data("f.bin", count: 5000)
        let result = await run(try plan([original], into: destination.url), chunk: 1000)
        let progress = result.events.compactMap { event -> Int64? in
            if case .progress(_, let bytes, _, _) = event { bytes } else { nil }
        }
        #expect(progress == [1000, 2000, 3000, 4000, 5000])
    }

    @Test func symbolicLinksAreRecreatedAsLinks() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("real.txt")
        try FileManager.default.createSymbolicLink(atPath: source.path("l").path, withDestinationPath: "real.txt")
        _ = await run(try plan([source.path("l")], into: destination.url))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path("l").path) == "real.txt")
    }

    @Test func modificationDatesAreKept() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try source.setModified("a.txt", date)
        _ = await run(try plan([source.path("a.txt")], into: destination.url))
        let copied = try PosixFileAccess().attributes(of: destination.path("a.txt"))
        #expect(abs(copied.modified.timeIntervalSince(date)) < 1)
    }

    // MARK: Conflicts

    private func conflict(_ choice: ConflictChoice, sourceIsNewer: Bool) async throws -> (TempFolder, TransferOutcome) {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let older = Date(timeIntervalSince1970: 1_000_000_000)
        let newer = Date(timeIntervalSince1970: 1_600_000_000)
        try source.setModified("a.txt", sourceIsNewer ? newer : older)
        try destination.setModified("a.txt", sourceIsNewer ? older : newer)
        let jobs = try plan([source.path("a.txt")], into: destination.url)
        let result = await run(jobs, prompts: choosing(choice))
        return (destination, result.outcome)
    }

    @Test func replaceOverwritesTheExistingFile() async throws {
        let (destination, outcome) = try await conflict(.replace, sourceIsNewer: false)
        #expect(try destination.text("a.txt") == "new")
        #expect(outcome.copied == 1)
    }

    @Test func keepBothAddsANumberedCopy() async throws {
        let (destination, _) = try await conflict(.keepBoth, sourceIsNewer: false)
        #expect(try destination.text("a.txt") == "old")
        #expect(try destination.text("a 2.txt") == "new")
    }

    @Test func skipLeavesTheExistingFile() async throws {
        let (destination, outcome) = try await conflict(.skip, sourceIsNewer: true)
        #expect(try destination.text("a.txt") == "old")
        #expect(outcome.skipped == 1)
        #expect(outcome.copied == 0)
    }

    @Test func replaceIfNewerReplacesOnlyWhenTheSourceIsNewer() async throws {
        let (replaced, _) = try await conflict(.replaceIfNewer, sourceIsNewer: true)
        #expect(try replaced.text("a.txt") == "new")
        let (kept, outcome) = try await conflict(.replaceIfNewer, sourceIsNewer: false)
        #expect(try kept.text("a.txt") == "old")
        #expect(outcome.skipped == 1)
    }

    @Test func applyToAllAsksOnlyOnce() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["a.txt", "b.txt", "c.txt"] {
            try source.file(name, "new")
            try destination.file(name, "old")
        }
        let jobs = try plan(["a.txt", "b.txt", "c.txt"].map { source.path($0) }, into: destination.url)
        let asked = Counter()
        let result = await run(jobs, prompts: choosing(.replace, applyToAll: true, counter: asked))
        #expect(asked.value == 1)
        #expect(result.outcome.copied == 3)
        #expect(try destination.text("c.txt") == "new")
    }

    @Test func copyingAFileOntoItselfMakesANumberedCopyWithoutAsking() async throws {
        let source = try TempFolder()
        let file = try source.file("a.txt", "same")
        let asked = Counter()
        let result = await run(try plan([file], into: source.url), prompts: choosing(.replace, counter: asked))
        #expect(asked.value == 0)
        #expect(result.outcome.copied == 1)
        #expect(try source.text("a 2.txt") == "same")
        #expect(try source.text("a.txt") == "same")
    }

    @Test func aFolderWhereAFileIsExpectedFailsThatItemOnly() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("x", "file")
        try destination.folder("x")
        try source.file("y", "ok")
        let jobs = try plan([source.path("x"), source.path("y")], into: destination.url)
        let result = await run(jobs)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.copied == 1)
        let reasons = result.events.compactMap { event -> TransferFailureReason? in
            if case .failed(_, let failure) = event { failure.reason } else { nil }
        }
        #expect(reasons == [.conflictingKind])
    }

    // MARK: Errors

    @Test func anUnreadableFileFailsAndTheRunContinues() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "xxxx")
        try source.file("good.bin", "yyyy")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let jobs = try plan(["bad.bin", "good.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky)

        #expect(result.outcome.stop == .finished)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.copied == 1)
        #expect(try destination.names() == ["good.bin"])
        let reasons = result.events.compactMap { event -> TransferFailureReason? in
            if case .failed(_, let failure) = event { failure.reason } else { nil }
        }
        #expect(reasons == [.unreadable])
    }

    @Test func runningOutOfSpaceStopsAndKeepsTheRestWaiting() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["a.bin", "b.bin", "c.bin"] { try source.file(name, "data") }
        let flaky = Flaky()
        flaky.update { $0.failWriting = ["b.bin": .ENOSPC] }
        let jobs = try plan(["a.bin", "b.bin", "c.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky)

        #expect(result.outcome.stop == .noSpace)
        #expect(result.outcome.remaining.map(\.name) == ["b.bin", "c.bin"])
        #expect(try destination.names() == ["a.bin"])
        let failed = result.events.filter { if case .failed = $0 { true } else { false } }
        #expect(failed.isEmpty)
    }

    @Test func aVanishedDriveStopsTheRun() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.bin", "data")
        try source.file("b.bin", "data")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["b.bin"]; $0.vanished = true }
        let jobs = try plan(["a.bin", "b.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky)

        #expect(result.outcome.stop == .driveRemoved)
        #expect(result.outcome.remaining.map(\.name) == ["b.bin"])
    }

    @Test func askingOnErrorCanRetryThenSkip() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "data")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let asked = Counter()
        let answers = Counter()
        let prompts = TransferPrompts(
            conflict: { _ in ConflictDecision(choice: .skip) },
            error: { _ in
                asked.increment()
                answers.increment()
                return ErrorDecision(choice: answers.value == 1 ? .retry : .skip)
            })

        let result = await run(try plan([source.path("bad.bin")], into: destination.url), access: flaky, askOnError: true, prompts: prompts)

        #expect(asked.value == 2)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.stop == .finished)
    }

    @Test func choosingStopEndsTheRunAndKeepsTheRest() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        for name in ["bad.bin", "next.bin"] { try source.file(name, "data") }
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let prompts = TransferPrompts(
            conflict: { _ in ConflictDecision(choice: .skip) },
            error: { _ in ErrorDecision(choice: .stop) })
        let jobs = try plan(["bad.bin", "next.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky, askOnError: true, prompts: prompts)

        #expect(result.outcome.stop == .userStopped)
        #expect(result.outcome.failed == 1)
        #expect(result.outcome.remaining.map(\.name) == ["next.bin"])
    }

    // MARK: Verification

    @Test func verifyAcceptsAnIdenticalCopy() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("a.bin", count: 5000)
        let result = await run(try plan([source.path("a.bin")], into: destination.url), verify: true)
        #expect(result.outcome.copied == 1)
        #expect(result.outcome.failed == 0)
    }

    @Test func verifyCatchesACorruptedCopyAndRemovesIt() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("b.bin", count: 5000)
        try source.data("c.bin", count: 100)
        let flaky = Flaky()
        flaky.update { $0.corrupt = ["b.bin"] }
        let jobs = try plan(["b.bin", "c.bin"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, access: flaky, verify: true)

        #expect(result.outcome.failed == 1)
        #expect(result.outcome.copied == 1)
        #expect(try destination.names() == ["c.bin"])
        let reasons = result.events.compactMap { event -> TransferFailureReason? in
            if case .failed(_, let failure) = event { failure.reason } else { nil }
        }
        #expect(reasons == [.checksumMismatch])
    }

    // MARK: Control

    @Test func aPausedEngineDoesNothingUntilResumed() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let jobs = try plan([source.path("a.txt")], into: destination.url)
        let control = TransferControl()
        control.pause()

        let task = Task { await run(jobs, control: control) }
        try await Task.sleep(for: .milliseconds(250))
        #expect(!destination.has("a.txt"))

        control.resume()
        let result = await task.value
        #expect(result.outcome.copied == 1)
        #expect(destination.has("a.txt"))
    }

    @Test func cancellingBeforeTheStartCopiesNothing() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        try source.file("b.txt")
        let jobs = try plan(["a.txt", "b.txt"].map { source.path($0) }, into: destination.url)
        let control = TransferControl()
        control.cancel()

        let result = await run(jobs, control: control)

        #expect(result.outcome.stop == .cancelled)
        #expect(result.outcome.remaining.count == 2)
        #expect(try destination.names().isEmpty)
    }

    @Test func cancellingMidFileRemovesThePartialCopy() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("big.bin", count: 10_000)
        let control = TransferControl()
        let jobs = try plan([source.path("big.bin")], into: destination.url)

        let result = await run(jobs, chunk: 1000, control: control) { event in
            if case .progress(_, let bytes, _, _) = event, bytes >= 3000 { control.cancel() }
        }

        #expect(result.outcome.stop == .cancelled)
        #expect(try destination.names().isEmpty)
    }

    @Test func skippingTheCurrentFileMovesOnToTheNextOne() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("big.bin", count: 10_000)
        try source.file("small.txt", "ok")
        let control = TransferControl()
        let jobs = try plan(["big.bin", "small.txt"].map { source.path($0) }, into: destination.url)

        let result = await run(jobs, chunk: 1000, control: control) { event in
            if case .progress(_, let bytes, _, _) = event, bytes == 2000 { control.skipCurrent() }
        }

        #expect(result.outcome.skipped == 1)
        #expect(result.outcome.copied == 1)
        #expect(try destination.names() == ["small.txt"])
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --package-path Core --filter TransferEngineTests`
Expected: `cannot find 'TransferEngine' in scope` (and the other engine types).

- [ ] **Step 4: Implement** — `Core/Sources/NTFSTransfer/TransferEngine.swift`

```swift
import CryptoKit
import Foundation

public struct TransferOptions: Sendable, Equatable {
    public var verify: Bool
    public var askOnError: Bool
    public var chunkSize: Int
    /// How often progress events are sent while a file is copying.
    public var progressInterval: Duration

    public init(
        verify: Bool = false, askOnError: Bool = false,
        chunkSize: Int = 4 * 1024 * 1024, progressInterval: Duration = .milliseconds(150)
    ) {
        self.verify = verify
        self.askOnError = askOnError
        self.chunkSize = chunkSize
        self.progressInterval = progressInterval
    }
}

public enum ConflictChoice: Sendable, Equatable {
    case replace, keepBoth, skip, replaceIfNewer
}

public struct ConflictDecision: Sendable, Equatable {
    public var choice: ConflictChoice
    public var applyToAll: Bool

    public init(choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct ConflictInfo: Sendable, Equatable {
    public var name: String
    public var source: FileAttributes
    public var existing: FileAttributes

    public init(name: String, source: FileAttributes, existing: FileAttributes) {
        self.name = name
        self.source = source
        self.existing = existing
    }
}

public enum ErrorChoice: Sendable, Equatable {
    case skip, retry, stop
}

public struct ErrorDecision: Sendable, Equatable {
    public var choice: ErrorChoice
    public var applyToAll: Bool

    public init(choice: ErrorChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct ErrorInfo: Sendable, Equatable {
    public var name: String
    public var failure: TransferFailure

    public init(name: String, failure: TransferFailure) {
        self.name = name
        self.failure = failure
    }
}

/// How the engine asks the person using the app what to do.
public struct TransferPrompts: Sendable {
    public var conflict: @Sendable (ConflictInfo) async -> ConflictDecision
    public var error: @Sendable (ErrorInfo) async -> ErrorDecision

    public init(
        conflict: @escaping @Sendable (ConflictInfo) async -> ConflictDecision,
        error: @escaping @Sendable (ErrorInfo) async -> ErrorDecision
    ) {
        self.conflict = conflict
        self.error = error
    }

    /// Never asks: skips files that already exist and failed files.
    public static let automatic = TransferPrompts(
        conflict: { _ in ConflictDecision(choice: .skip, applyToAll: true) },
        error: { _ in ErrorDecision(choice: .skip, applyToAll: true) })
}

public enum TransferEvent: Sendable, Equatable {
    case started(job: Int)
    case progress(job: Int, bytes: Int64, readRate: Double, writeRate: Double)
    case finished(job: Int, bytes: Int64)
    case skipped(job: Int)
    case failed(job: Int, TransferFailure)
}

public enum TransferStop: Sendable, Equatable {
    case finished, cancelled, noSpace, driveRemoved, userStopped
}

public struct TransferOutcome: Sendable, Equatable {
    public var stop: TransferStop = .finished
    /// Files and links created; folders are not counted.
    public var copied = 0
    public var failed = 0
    public var skipped = 0
    public var bytes: Int64 = 0
    /// Jobs not attempted, including the one that was interrupted when the run stopped.
    public var remaining: [TransferJob] = []

    public init() {}
}

public struct TransferEngine: Sendable {
    public let access: any FileAccess
    public let options: TransferOptions

    public init(access: any FileAccess, options: TransferOptions = TransferOptions()) {
        self.access = access
        self.options = options
    }

    private enum Step {
        case done(Int64)
        case skipped
        case failed(TransferFailure)
        case cancelled
    }

    private enum Resolution {
        case proceed(URL)
        case skip
        case failed(TransferFailure)
    }

    /// Copies the jobs one after another, sending events as it goes, and says why it stopped.
    public func run(
        jobs: [TransferJob], control: TransferControl, prompts: TransferPrompts,
        emit: @Sendable (TransferEvent) -> Void
    ) async -> TransferOutcome {
        var outcome = TransferOutcome()
        var conflictMemo: ConflictChoice?
        var errorMemo: ErrorChoice?
        var index = 0
        while index < jobs.count {
            if control.isCancelled {
                outcome.stop = .cancelled
                outcome.remaining = Array(jobs[index...])
                return outcome
            }
            await control.waitWhilePaused()
            if control.isCancelled { continue }

            let job = jobs[index]
            control.clearSkip()
            emit(.started(job: job.id))
            let step = await perform(job, control: control, prompts: prompts, conflictMemo: &conflictMemo, emit: emit)
            switch step {
            case .done(let bytes):
                emit(.finished(job: job.id, bytes: bytes))
                if !job.isDirectory {
                    outcome.copied += 1
                    outcome.bytes += bytes
                }
            case .skipped:
                emit(.skipped(job: job.id))
                outcome.skipped += 1
            case .cancelled:
                outcome.stop = .cancelled
                outcome.remaining = Array(jobs[index...])
                return outcome
            case .failed(let failure):
                if failure.reason.stopsTransfer {
                    outcome.stop = failure.reason == .noSpace ? .noSpace : .driveRemoved
                    outcome.remaining = Array(jobs[index...])
                    return outcome
                }
                var choice = ErrorChoice.skip
                if options.askOnError {
                    if let errorMemo {
                        choice = errorMemo
                    } else {
                        let decision = await prompts.error(ErrorInfo(name: job.name, failure: failure))
                        choice = decision.choice
                        if decision.applyToAll, decision.choice != .retry { errorMemo = decision.choice }
                    }
                }
                switch choice {
                case .retry:
                    continue
                case .skip:
                    emit(.failed(job: job.id, failure))
                    outcome.failed += 1
                case .stop:
                    emit(.failed(job: job.id, failure))
                    outcome.failed += 1
                    outcome.stop = .userStopped
                    outcome.remaining = Array(jobs[(index + 1)...])
                    return outcome
                }
            }
            index += 1
        }
        return outcome
    }

    // MARK: One job

    private func perform(
        _ job: TransferJob, control: TransferControl, prompts: TransferPrompts,
        conflictMemo: inout ConflictChoice?, emit: @Sendable (TransferEvent) -> Void
    ) async -> Step {
        switch job.kind {
        case .directory:
            do {
                if let existing = try? access.attributes(of: job.destination) {
                    return existing.kind == .directory ? .done(0) : .failed(TransferFailure(.conflictingKind))
                }
                try access.makeDirectory(job.destination)
                return .done(0)
            } catch {
                return .failed(adjusted(.classify(error, reading: false), for: job))
            }
        case .file, .symlink:
            let destination: URL
            switch await resolveConflict(job, prompts: prompts, memo: &conflictMemo) {
            case .proceed(let url): destination = url
            case .skip: return .skipped
            case .failed(let failure): return .failed(failure)
            }
            if case .symlink(let target) = job.kind {
                do {
                    if access.exists(destination) { try access.remove(destination) }
                    try access.makeLink(at: destination, target: target)
                    return .done(0)
                } catch {
                    return .failed(adjusted(.classify(error, reading: false), for: job))
                }
            }
            return await copy(job, to: destination, control: control, emit: emit)
        }
    }

    private func resolveConflict(
        _ job: TransferJob, prompts: TransferPrompts, memo: inout ConflictChoice?
    ) async -> Resolution {
        guard let existing = try? access.attributes(of: job.destination) else { return .proceed(job.destination) }
        if existing.kind == .directory { return .failed(TransferFailure(.conflictingKind)) }
        if job.source.standardizedFileURL.path == job.destination.standardizedFileURL.path {
            return .proceed(UniqueName.make(for: job.destination, exists: access.exists))
        }
        let choice: ConflictChoice
        if let memo {
            choice = memo
        } else {
            let info = ConflictInfo(
                name: job.name,
                source: FileAttributes(kind: .file, size: job.size, modified: job.modified),
                existing: existing)
            let decision = await prompts.conflict(info)
            choice = decision.choice
            if decision.applyToAll { memo = decision.choice }
        }
        switch choice {
        case .replace: return .proceed(job.destination)
        case .keepBoth: return .proceed(UniqueName.make(for: job.destination, exists: access.exists))
        case .skip: return .skip
        case .replaceIfNewer: return job.modified > existing.modified ? .proceed(job.destination) : .skip
        }
    }

    private func copy(
        _ job: TransferJob, to destination: URL, control: TransferControl,
        emit: @Sendable (TransferEvent) -> Void
    ) async -> Step {
        let temp = destination.deletingLastPathComponent().appending(component: ".\(destination.lastPathComponent).ntfs-part")
        var reader: (any FileReading)?
        var writer: (any FileWriting)?
        var reading = true

        func cleanUp() {
            reader?.close()
            reader = nil
            try? writer?.close()
            writer = nil
            try? access.remove(temp)
        }

        do {
            reader = try access.openForReading(job.source)
            reading = false
            writer = try access.createForWriting(temp)
            var hasher = SHA256()
            var done: Int64 = 0
            var meter = RateMeter()
            let clock = ContinuousClock()
            var lastEmit = clock.now

            while true {
                if control.isCancelled {
                    cleanUp()
                    return .cancelled
                }
                if control.takeSkip() {
                    cleanUp()
                    return .skipped
                }
                await control.waitWhilePaused()
                if control.isCancelled { continue }

                reading = true
                let readStart = clock.now
                let chunk = try reader!.read(upTo: options.chunkSize)
                meter.addRead(bytes: chunk.count, seconds: Self.seconds(clock.now - readStart))
                if chunk.isEmpty { break }
                if options.verify { hasher.update(data: chunk) }

                reading = false
                let writeStart = clock.now
                try writer!.write(chunk)
                meter.addWrite(bytes: chunk.count, seconds: Self.seconds(clock.now - writeStart))
                done += Int64(chunk.count)

                if clock.now - lastEmit >= options.progressInterval {
                    let rates = meter.takeRates()
                    emit(.progress(job: job.id, bytes: done, readRate: rates.read, writeRate: rates.write))
                    lastEmit = clock.now
                }
            }

            try writer?.sync()
            try writer?.close()
            writer = nil
            reader?.close()
            reader = nil
            if done != job.size { throw TransferFailure(.sizeMismatch) }
            if options.verify, try hash(of: temp) != Data(hasher.finalize()) {
                throw TransferFailure(.checksumMismatch)
            }
            try access.rename(temp, to: destination)
            access.copyMetadata(from: job.source, to: destination)
            return .done(done)
        } catch let failure as TransferFailure {
            cleanUp()
            return .failed(failure)
        } catch {
            cleanUp()
            return .failed(adjusted(.classify(error, reading: reading), for: job, destination: destination))
        }
    }

    private func hash(of url: URL) throws -> Data {
        let reader = try access.openForReading(url)
        defer { reader.close() }
        var hasher = SHA256()
        while true {
            let chunk = try reader.read(upTo: options.chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// An I/O error on a folder that has vanished means a drive was pulled out.
    private func adjusted(_ failure: TransferFailure, for job: TransferJob, destination: URL? = nil) -> TransferFailure {
        switch failure.reason {
        case .unreadable, .writeFailed, .sourceMissing:
            let destinationFolder = (destination ?? job.destination).deletingLastPathComponent()
            if !access.exists(job.source.deletingLastPathComponent()) || !access.exists(destinationFolder) {
                return TransferFailure(.driveRemoved, detail: failure.detail)
            }
            return failure
        default:
            return failure
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path Core --filter TransferEngineTests`
Expected: 22 tests pass. If `aVanishedDriveStopsTheRun` fails because the first file's `UniqueName`/`exists` call sees `vanished`, check that `resolveConflict` only uses `attributes` (it does) and that the flaky `exists` is used only in `adjusted` for a plain copy.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/NTFSTransfer Core/Tests/NTFSTransferTests
git commit -m "Add the transfer engine: chunked copy, conflicts, errors, verify, pause and cancel." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 6: Progress aggregation and the observable queue

**Files:**
- Create: `Core/Sources/NTFSTransfer/TransferProgress.swift`
- Create: `Core/Sources/NTFSTransfer/TransferQueue.swift`
- Create: `Core/Tests/NTFSTransferTests/TransferProgressTests.swift`
- Create: `Core/Tests/NTFSTransferTests/TransferQueueTests.swift`

**Interfaces:**
- Consumes: Task 5 types.
- Produces: `TransferItem` (`job`, `state`, `bytesDone`, `failure`), `TransferItem.State` (`waiting`, `copying`, `done`, `failed(TransferFailure)`, `skipped`), `TransferSummary` (`copied`, `failed`, `skipped`, `bytes`, `duration`, public memberwise init), `TransferProgress` (`items`, `readRate`, `writeRate`, `activeSeconds`, `append(_:)`, `apply(_:at:)`, `resetFailed() -> [TransferJob]`, `interrupted()`, `cancelRemaining()`, `summary()`, derived `totalBytes`, `processedBytes`, `fraction`, `fileCount`, `doneCount`, `failedItems`, `effectiveRate`, `secondsRemaining`), `ConflictRequest`, `ErrorRequest`, `TransferQueue` (`phase`, `progress`, `summary`, `conflict`, `errorPrompt`, `options`, `isBusy`, `onProgress`, `onFinish`, `enqueue(_:)`, `pause()`, `resume()`, `skipCurrent()`, `cancel()`, `cancelAndWait()`, `retryFailed()`, `clear()`, `answer(_:)`, `answerError(_:)`).

- [ ] **Step 1: Write the failing tests** — `TransferProgressTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@Suite struct TransferProgressTests {
    private func job(_ id: Int, size: Int64, kind: TransferJob.Kind = .file) -> TransferJob {
        TransferJob(
            id: id, kind: kind, source: URL(fileURLWithPath: "/s/\(id)"),
            destination: URL(fileURLWithPath: "/d/\(id)"), size: size)
    }

    private let start = Date(timeIntervalSince1970: 0)

    @Test func totalsIgnoreFolders() {
        var progress = TransferProgress()
        progress.append([job(0, size: 0, kind: .directory), job(1, size: 100), job(2, size: 300)])
        #expect(progress.totalBytes == 400)
        #expect(progress.fileCount == 2)
        #expect(progress.processedBytes == 0)
        #expect(progress.fraction == 0)
    }

    @Test func eventsMoveItemsThroughTheirStates() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100), job(1, size: 100)])
        progress.apply(.started(job: 0), at: start)
        #expect(progress.items[0].state == .copying)
        progress.apply(.progress(job: 0, bytes: 40, readRate: 0, writeRate: 0), at: start)
        #expect(progress.processedBytes == 40)
        progress.apply(.finished(job: 0, bytes: 100), at: start)
        #expect(progress.items[0].state == .done)
        #expect(progress.doneCount == 1)
        #expect(progress.fraction == 0.5)
    }

    @Test func failedAndSkippedFilesCountAsProcessedSoTheBarReachesTheEnd() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100), job(1, size: 100)])
        progress.apply(.failed(job: 0, TransferFailure(.unreadable)), at: start)
        progress.apply(.skipped(job: 1), at: start)
        #expect(progress.fraction == 1)
        #expect(progress.failedItems.map(\.id) == [0])
        #expect(progress.items[0].failure?.reason == .unreadable)
    }

    @Test func onlyEmptyFilesFallBackToCountingFiles() {
        var progress = TransferProgress()
        progress.append([job(0, size: 0), job(1, size: 0)])
        progress.apply(.finished(job: 0, bytes: 0), at: start)
        #expect(progress.fraction == 0.5)
    }

    @Test func effectiveRateCombinesReadingAndWriting() {
        var progress = TransferProgress()
        progress.append([job(0, size: 300_000_000)])
        progress.apply(.started(job: 0), at: start)
        progress.apply(.progress(job: 0, bytes: 100_000_000, readRate: 100e6, writeRate: 100e6), at: start)
        #expect(progress.effectiveRate == 50e6)
        // 200 MB left at 50 MB/s.
        #expect(progress.secondsRemaining == 4)
    }

    @Test func noRateMeansNoEstimate() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100)])
        #expect(progress.secondsRemaining == nil)
    }

    @Test func ratesAreSmoothedAndZeroSamplesAreIgnored() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100)])
        progress.apply(.progress(job: 0, bytes: 1, readRate: 100, writeRate: 100), at: start)
        progress.apply(.progress(job: 0, bytes: 2, readRate: 200, writeRate: 0), at: start)
        #expect(progress.readRate == 130)
        #expect(progress.writeRate == 100)
    }

    @Test func activeTimeCountsGapsBetweenEventsButCapsLongPauses() {
        var progress = TransferProgress()
        progress.append([job(0, size: 100)])
        progress.apply(.started(job: 0), at: start)
        progress.apply(.progress(job: 0, bytes: 1, readRate: 1, writeRate: 1), at: start.addingTimeInterval(1))
        progress.apply(.finished(job: 0, bytes: 100), at: start.addingTimeInterval(1000))
        #expect(progress.activeSeconds == 3)
    }

    @Test func resettingFailedItemsReturnsTheirJobsAsWaiting() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10), job(1, size: 10)])
        progress.apply(.finished(job: 0, bytes: 10), at: start)
        progress.apply(.failed(job: 1, TransferFailure(.writeFailed)), at: start)
        let retry = progress.resetFailed()
        #expect(retry.map(\.id) == [1])
        #expect(progress.items[1].state == .waiting)
        #expect(progress.failedItems.isEmpty)
    }

    @Test func interruptedPutsACopyingItemBackToWaiting() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10)])
        progress.apply(.started(job: 0), at: start)
        progress.interrupted()
        #expect(progress.items[0].state == .waiting)
        #expect(progress.items[0].bytesDone == 0)
    }

    @Test func cancellingMarksWhatIsLeftAsSkipped() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10), job(1, size: 10)])
        progress.apply(.finished(job: 0, bytes: 10), at: start)
        progress.cancelRemaining()
        #expect(progress.items.map(\.state) == [.done, .skipped])
    }

    @Test func summaryCountsOutcomesAndBytes() {
        var progress = TransferProgress()
        progress.append([job(0, size: 10), job(1, size: 20), job(2, size: 30), job(3, size: 0, kind: .directory)])
        progress.apply(.started(job: 0), at: start)
        progress.apply(.finished(job: 0, bytes: 10), at: start.addingTimeInterval(1))
        progress.apply(.finished(job: 1, bytes: 20), at: start.addingTimeInterval(2))
        progress.apply(.failed(job: 2, TransferFailure(.unreadable)), at: start.addingTimeInterval(3))
        let summary = progress.summary()
        #expect(summary.copied == 2)
        #expect(summary.failed == 1)
        #expect(summary.skipped == 0)
        #expect(summary.bytes == 30)
        #expect(summary.duration == 3)
    }
}
```

`TransferQueueTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
@Suite struct TransferQueueTests {
    @Test func copiesEverythingAndReportsTheSummary() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "alpha")
        try source.file("b.txt", "beta")
        let queue = TransferQueue()
        var finished: (TransferSummary, TransferStop)?
        queue.onFinish = { summary, stop in finished = (summary, stop) }

        queue.enqueue(try plan(["a.txt", "b.txt"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.summary?.copied == 2)
        #expect(finished?.0.copied == 2)
        #expect(finished?.1 == .finished)
        #expect(try destination.text("b.txt") == "beta")
        #expect(!queue.isBusy)
    }

    @Test func aSecondBatchWhileRunningIsAppendedAndRunsAfterTheFirst() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.data("one.bin", count: 2_000_000)
        try source.file("two.txt", "2")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("one.bin")], into: destination.url))
        queue.enqueue(try plan([source.path("two.txt")], into: destination.url))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.progress.fileCount == 2)
        #expect(queue.summary?.copied == 2)
        #expect(destination.has("two.txt"))
    }

    @Test func failedFilesCanBeRetried() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("bad.bin", "xxxx")
        try source.file("good.bin", "yyyy")
        let flaky = Flaky()
        flaky.update { $0.failReading = ["bad.bin"] }
        let queue = TransferQueue(access: flaky)
        queue.enqueue(try plan(["bad.bin", "good.bin"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.progress.failedItems.count == 1)
        #expect(queue.summary?.failed == 1)

        flaky.update { $0.failReading = [] }
        queue.retryFailed()
        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.progress.failedItems.isEmpty)
        #expect(queue.summary?.copied == 2)
        #expect(try destination.text("bad.bin") == "xxxx")
    }

    @Test func aConflictIsAskedThroughTheQueue() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "new")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        #expect(queue.conflict?.info.name == "a.txt")
        queue.answer(ConflictDecision(choice: .replace))

        #expect(await waitUntil { queue.phase == .finished })
        #expect(queue.conflict == nil)
        #expect(try destination.text("a.txt") == "new")
    }

    @Test func runningOutOfSpaceHaltsAndResumeContinues() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.bin", "aaaa")
        try source.file("b.bin", "bbbb")
        let flaky = Flaky()
        flaky.update { $0.failWriting = ["b.bin": .ENOSPC] }
        let queue = TransferQueue(access: flaky)
        queue.enqueue(try plan(["a.bin", "b.bin"].map { source.path($0) }, into: destination.url))

        #expect(await waitUntil { queue.phase == .stopped(.noSpace) })
        #expect(queue.progress.items.last?.state == .waiting)

        flaky.update { $0.failWriting = [:] }
        queue.resume()
        #expect(await waitUntil { queue.phase == .finished })
        #expect(try destination.text("b.bin") == "bbbb")
    }

    @Test func cancellingMarksTheRestSkippedAndFinishes() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt", "x")
        try destination.file("a.txt", "old")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))

        #expect(await waitUntil { queue.conflict != nil })
        await queue.cancelAndWait()

        #expect(queue.phase == .finished)
        #expect(queue.progress.items.allSatisfy { $0.state == .skipped })
        #expect(try destination.text("a.txt") == "old")
    }

    @Test func clearingAFinishedQueueGoesBackToIdle() async throws {
        let source = try TempFolder()
        let destination = try TempFolder()
        try source.file("a.txt")
        let queue = TransferQueue()
        queue.enqueue(try plan([source.path("a.txt")], into: destination.url))
        #expect(await waitUntil { queue.phase == .finished })
        queue.clear()
        #expect(queue.phase == .idle)
        #expect(queue.progress.items.isEmpty)
        #expect(queue.summary == nil)
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path Core --filter "TransferProgressTests|TransferQueueTests"`
Expected: `cannot find 'TransferProgress' in scope`.

- [ ] **Step 3: Implement** — `TransferProgress.swift`

```swift
import Foundation

public struct TransferItem: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case waiting
        case copying
        case done
        case failed(TransferFailure)
        case skipped
    }

    public var job: TransferJob
    public var state: State = .waiting
    public var bytesDone: Int64 = 0

    public var id: Int { job.id }

    public var failure: TransferFailure? {
        if case .failed(let failure) = state { failure } else { nil }
    }
}

public struct TransferSummary: Sendable, Equatable {
    public var copied: Int
    public var failed: Int
    public var skipped: Int
    public var bytes: Int64
    public var duration: TimeInterval

    public init(copied: Int, failed: Int, skipped: Int, bytes: Int64, duration: TimeInterval) {
        self.copied = copied
        self.failed = failed
        self.skipped = skipped
        self.bytes = bytes
        self.duration = duration
    }
}

/// What the progress panel shows, built from the engine's events.
public struct TransferProgress: Sendable, Equatable {
    public private(set) var items: [TransferItem] = []
    public private(set) var readRate = 0.0
    public private(set) var writeRate = 0.0
    public private(set) var activeSeconds = 0.0
    private var lastEvent: Date?
    private var indexByID: [Int: Int] = [:]

    public init() {}

    public mutating func append(_ jobs: [TransferJob]) {
        for job in jobs {
            indexByID[job.id] = items.count
            items.append(TransferItem(job: job))
        }
    }

    public mutating func apply(_ event: TransferEvent, at date: Date) {
        if let lastEvent {
            activeSeconds += min(max(date.timeIntervalSince(lastEvent), 0), 2)
        }
        lastEvent = date
        switch event {
        case .started(let id):
            update(id) { $0.state = .copying; $0.bytesDone = 0 }
        case .progress(let id, let bytes, let read, let write):
            update(id) { $0.bytesDone = bytes }
            readRate = Self.smooth(readRate, read)
            writeRate = Self.smooth(writeRate, write)
        case .finished(let id, let bytes):
            update(id) { $0.state = .done; $0.bytesDone = bytes }
        case .skipped(let id):
            update(id) { $0.state = .skipped }
        case .failed(let id, let failure):
            update(id) { $0.state = .failed(failure) }
        }
    }

    /// Puts the failed items back to waiting and returns their jobs to run again.
    public mutating func resetFailed() -> [TransferJob] {
        var jobs: [TransferJob] = []
        for index in items.indices where items[index].failure != nil {
            items[index].state = .waiting
            items[index].bytesDone = 0
            jobs.append(items[index].job)
        }
        return jobs
    }

    /// A run ended with a file half done: it will start over, so show it as waiting.
    public mutating func interrupted() {
        for index in items.indices where items[index].state == .copying {
            items[index].state = .waiting
            items[index].bytesDone = 0
        }
    }

    public mutating func cancelRemaining() {
        for index in items.indices where items[index].state == .waiting || items[index].state == .copying {
            items[index].state = .skipped
        }
    }

    public func summary() -> TransferSummary {
        var copied = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        for item in items where !item.job.isDirectory {
            switch item.state {
            case .done:
                copied += 1
                bytes += item.bytesDone
            case .failed: failed += 1
            case .skipped: skipped += 1
            case .waiting, .copying: break
            }
        }
        return TransferSummary(copied: copied, failed: failed, skipped: skipped, bytes: bytes, duration: activeSeconds)
    }

    // MARK: Derived

    private var files: [TransferItem] { items.filter { !$0.job.isDirectory } }

    public var fileCount: Int { files.count }

    public var doneCount: Int { files.filter { $0.state == .done }.count }

    public var failedItems: [TransferItem] { items.filter { $0.failure != nil } }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.job.size } }

    public var processedBytes: Int64 {
        files.reduce(0) { sum, item in
            switch item.state {
            case .waiting: sum
            case .copying: sum + min(item.bytesDone, item.job.size)
            case .done, .failed, .skipped: sum + item.job.size
            }
        }
    }

    public var fraction: Double {
        let total = totalBytes
        if total > 0 { return Double(processedBytes) / Double(total) }
        let count = fileCount
        guard count > 0 else { return 0 }
        let processed = files.filter { $0.state != .waiting && $0.state != .copying }.count
        return Double(processed) / Double(count)
    }

    /// Reading and writing alternate, so the speed of the whole is the two combined in series.
    public var effectiveRate: Double {
        guard readRate > 0, writeRate > 0 else { return max(readRate, writeRate) }
        return 1 / (1 / readRate + 1 / writeRate)
    }

    public var secondsRemaining: Double? {
        let rate = effectiveRate
        let left = totalBytes - processedBytes
        guard rate > 0, left >= 0 else { return nil }
        return Double(left) / rate
    }

    private mutating func update(_ id: Int, _ change: (inout TransferItem) -> Void) {
        if let index = indexByID[id] { change(&items[index]) }
    }

    private static func smooth(_ old: Double, _ new: Double) -> Double {
        guard new > 0 else { return old }
        return old == 0 ? new : old * 0.7 + new * 0.3
    }
}
```

`TransferQueue.swift`

```swift
import Foundation
import Observation

/// A question from the engine waiting for the person using the app.
@MainActor
public final class ConflictRequest: Identifiable {
    public let id = UUID()
    public let info: ConflictInfo
    private var completion: ((ConflictDecision) -> Void)?

    init(info: ConflictInfo, completion: @escaping (ConflictDecision) -> Void) {
        self.info = info
        self.completion = completion
    }

    func resolve(_ decision: ConflictDecision) {
        completion?(decision)
        completion = nil
    }
}

@MainActor
public final class ErrorRequest: Identifiable {
    public let id = UUID()
    public let info: ErrorInfo
    private var completion: ((ErrorDecision) -> Void)?

    init(info: ErrorInfo, completion: @escaping (ErrorDecision) -> Void) {
        self.info = info
        self.completion = completion
    }

    func resolve(_ decision: ErrorDecision) {
        completion?(decision)
        completion = nil
    }
}

/// Runs batches of jobs one after another and holds everything the progress panel shows.
@MainActor
@Observable
public final class TransferQueue {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case paused
        /// Out of space or a drive was removed: waiting for `resume()`.
        case stopped(TransferStop)
        case finished
    }

    public private(set) var progress = TransferProgress()
    public private(set) var phase: Phase = .idle
    public private(set) var summary: TransferSummary?
    public private(set) var conflict: ConflictRequest?
    public private(set) var errorPrompt: ErrorRequest?
    /// Read when a batch starts, so changes apply to the next batch.
    public var options = TransferOptions()

    @ObservationIgnored public var onProgress: (@MainActor (TransferProgress) -> Void)?
    @ObservationIgnored public var onFinish: (@MainActor (TransferSummary, TransferStop) -> Void)?

    @ObservationIgnored private let access: any FileAccess
    @ObservationIgnored private var control = TransferControl()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var batches: [[TransferJob]] = []
    @ObservationIgnored private var nextID = 0

    public init(access: any FileAccess = PosixFileAccess()) {
        self.access = access
    }

    public var isBusy: Bool { phase == .running || phase == .paused }

    private var isHalted: Bool {
        if case .stopped = phase { true } else { false }
    }

    // MARK: Commands

    public func enqueue(_ jobs: [TransferJob]) {
        guard !jobs.isEmpty else { return }
        if phase == .finished || phase == .idle {
            progress = TransferProgress()
            summary = nil
        }
        let numbered = jobs.map { job -> TransferJob in
            var job = job
            job.id = nextID
            nextID += 1
            return job
        }
        progress.append(numbered)
        batches.append(numbered)
        if task == nil, !isHalted { startNext() }
    }

    public func pause() {
        guard phase == .running else { return }
        control.pause()
        phase = .paused
    }

    public func resume() {
        switch phase {
        case .paused:
            control.resume()
            phase = .running
        case .stopped:
            summary = nil
            startNext()
        default:
            break
        }
    }

    public func skipCurrent() { control.skipCurrent() }

    public func cancel() {
        control.cancel()
        answer(ConflictDecision(choice: .skip))
        answerError(ErrorDecision(choice: .skip))
        if task == nil {
            batches.removeAll()
            progress.cancelRemaining()
            finish(.cancelled)
        }
    }

    public func cancelAndWait() async {
        cancel()
        await task?.value
    }

    /// Runs the failed files again.
    public func retryFailed() {
        let jobs = progress.resetFailed()
        guard !jobs.isEmpty else { return }
        summary = nil
        batches.append(jobs)
        if task == nil, !isHalted { startNext() }
    }

    /// Empties a finished list.
    public func clear() {
        guard !isBusy, !isHalted else { return }
        progress = TransferProgress()
        summary = nil
        phase = .idle
    }

    public func answer(_ decision: ConflictDecision) {
        let request = conflict
        conflict = nil
        request?.resolve(decision)
    }

    public func answerError(_ decision: ErrorDecision) {
        let request = errorPrompt
        errorPrompt = nil
        request?.resolve(decision)
    }

    // MARK: Running

    private func startNext() {
        guard task == nil, !batches.isEmpty else { return }
        let jobs = batches.removeFirst()
        control = TransferControl()
        let control = control
        phase = .running
        let engine = TransferEngine(access: access, options: options)
        let prompts = TransferPrompts(
            conflict: { [weak self] info in
                await self?.askConflict(info) ?? ConflictDecision(choice: .skip)
            },
            error: { [weak self] info in
                await self?.askError(info) ?? ErrorDecision(choice: .skip)
            })
        task = Task { [weak self] in
            let (events, continuation) = AsyncStream<TransferEvent>.makeStream()
            let runner = Task.detached(priority: .utility) {
                let outcome = await engine.run(jobs: jobs, control: control, prompts: prompts) { continuation.yield($0) }
                continuation.finish()
                return outcome
            }
            for await event in events {
                self?.apply(event)
            }
            let outcome = await runner.value
            self?.runEnded(outcome)
        }
    }

    private func apply(_ event: TransferEvent) {
        progress.apply(event, at: Date())
        onProgress?(progress)
    }

    private func askConflict(_ info: ConflictInfo) async -> ConflictDecision {
        await withCheckedContinuation { continuation in
            conflict = ConflictRequest(info: info) { continuation.resume(returning: $0) }
        }
    }

    private func askError(_ info: ErrorInfo) async -> ErrorDecision {
        await withCheckedContinuation { continuation in
            errorPrompt = ErrorRequest(info: info) { continuation.resume(returning: $0) }
        }
    }

    private func runEnded(_ outcome: TransferOutcome) {
        task = nil
        progress.interrupted()
        switch outcome.stop {
        case .finished:
            if batches.isEmpty { finish(.finished) } else { startNext() }
        case .cancelled, .userStopped:
            batches.removeAll()
            progress.cancelRemaining()
            finish(outcome.stop)
        case .noSpace, .driveRemoved:
            batches.insert(outcome.remaining, at: 0)
            phase = .stopped(outcome.stop)
            let summary = progress.summary()
            self.summary = summary
            onProgress?(progress)
            onFinish?(summary, outcome.stop)
        }
    }

    private func finish(_ stop: TransferStop) {
        phase = .finished
        let summary = progress.summary()
        self.summary = summary
        onProgress?(progress)
        onFinish?(summary, stop)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter "TransferProgressTests|TransferQueueTests"`
Expected: 12 progress tests and 7 queue tests pass. If Swift 6 reports a data-race error on the `conflict:`/`error:` closures capturing `self`, keep `[weak self]` and make sure both closures are `@Sendable` through the `TransferPrompts` initializer (they are). If `activeSeconds == 3` fails, recheck: events at t=0 (first, no gap), t=1 (+1), t=1000 (+2 cap) = 3.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/NTFSTransfer Core/Tests/NTFSTransferTests
git commit -m "Aggregate engine events into progress and run batches through an observable queue." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 7: Folder browsing, locations, file operations

**Files:**
- Create: `Core/Sources/NTFSTransfer/FileBrowser.swift`
- Create: `Core/Tests/NTFSTransferTests/FileBrowserTests.swift`

**Interfaces:**
- Consumes: `FileAccess`, `PosixFileAccess`, `FileKind` (Tasks 1–2).
- Produces: `FileEntry` (`url`, `name`, `isFolder`, `size`, `modified`, `isHidden`, `id`), `FileSortKey`, `FileSort` (`key`, `ascending`), `FileSorter.sorted(_:by:)`, `DirectoryLister.list(_:access:showHidden:)`, `FileBrowserModel` (`folder`, `entries`, `errorMessage`, `freeBytes`, `isLoading`, `selection`, `sort`, `showsHidden`, `canGoBack`, `canGoForward`, `canGoUp`, `selectedEntries`, `open(_:)`, `goBack()`, `goForward()`, `goUp()`, `reload() async`), `FileLocation` (`name`, `url`, `symbol`), `Locations.available()`, `Locations.containing(_:in:)`, `FileOperations` (`validate(_:)`, `makeFolder(named:in:)`, `rename(_:to:)`, `trash(_:)`, `deletePermanently(_:)`), `FileOperationError`.

- [ ] **Step 1: Write the failing tests** — `FileBrowserTests.swift`

```swift
import Foundation
import Testing
@testable import NTFSTransfer

@MainActor
@Suite struct FileBrowserModelTests {
    @Test func listsFoldersFirstThenFilesByName() async throws {
        let folder = try TempFolder()
        try folder.file("beta.txt"); try folder.file("alpha.txt"); try folder.folder("Zeta")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        #expect(model.entries.map(\.name) == ["Zeta", "alpha.txt", "beta.txt"])
        #expect(model.entries.first?.isFolder == true)
        #expect(model.errorMessage == nil)
        #expect((model.freeBytes ?? 0) > 0)
    }

    @Test func hiddenFilesAreOnlyShownOnRequest() async throws {
        let folder = try TempFolder()
        try folder.file(".secret"); try folder.file("shown")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        #expect(model.entries.map(\.name) == ["shown"])
        model.showsHidden = true // reloads by itself
        for _ in 0..<300 where model.entries.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(model.entries.map(\.name)) == [".secret", "shown"])
    }

    @Test func sortingBySizeDescendingKeepsFoldersFirst() async throws {
        let folder = try TempFolder()
        try folder.file("small", "1"); try folder.file("large", "12345"); try folder.folder("dir")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        model.sort = FileSort(key: .size, ascending: false)
        #expect(model.entries.map(\.name) == ["dir", "large", "small"])
    }

    @Test func navigationKeepsAHistory() async throws {
        let folder = try TempFolder()
        try folder.folder("inner")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        #expect(!model.canGoBack)

        model.open(folder.path("inner"))
        await model.reload()
        #expect(model.folder.lastPathComponent == "inner")
        #expect(model.canGoBack)

        model.goBack()
        await model.reload()
        #expect(model.folder.standardizedFileURL == folder.url.standardizedFileURL)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.folder.lastPathComponent == "inner")
        model.goUp()
        #expect(model.folder.standardizedFileURL == folder.url.standardizedFileURL)
    }

    @Test func aMissingFolderReportsAnErrorAndNoEntries() async throws {
        let folder = try TempFolder()
        let model = FileBrowserModel(folder: folder.path("missing"))
        await model.reload()
        #expect(model.errorMessage != nil)
        #expect(model.entries.isEmpty)
    }

    @Test func selectionDropsFilesThatDisappear() async throws {
        let folder = try TempFolder()
        try folder.file("a"); try folder.file("b")
        let model = FileBrowserModel(folder: folder.url)
        await model.reload()
        model.selection = Set(model.entries.map(\.url))
        try FileManager.default.removeItem(at: folder.path("a"))
        await model.reload()
        #expect(model.selection.map(\.lastPathComponent) == ["b"])
        #expect(model.selectedEntries.map(\.name) == ["b"])
    }
}

@Suite struct LocationsTests {
    @Test func containingPicksTheDeepestMatchOnAPathBoundary() {
        let places = [
            FileLocation(name: "Root", url: URL(fileURLWithPath: "/"), symbol: "internaldrive"),
            FileLocation(name: "Home", url: URL(fileURLWithPath: "/Users/me"), symbol: "house"),
            FileLocation(name: "Docs", url: URL(fileURLWithPath: "/Users/me/Documents"), symbol: "doc"),
        ]
        #expect(Locations.containing(URL(fileURLWithPath: "/Users/me/Documents/x"), in: places)?.name == "Docs")
        #expect(Locations.containing(URL(fileURLWithPath: "/Users/me/DocumentsOld"), in: places)?.name == "Home")
        #expect(Locations.containing(URL(fileURLWithPath: "/Applications"), in: places)?.name == "Root")
    }

    @Test func availableIncludesHomeAndAtLeastOneVolume() {
        let places = Locations.available()
        #expect(places.contains { $0.url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL })
        #expect(places.contains { $0.symbol.hasSuffix("drive") })
    }
}

@Suite struct FileOperationsTests {
    @Test func makeFolderCreatesItAndRefusesDuplicatesAndBadNames() throws {
        let folder = try TempFolder()
        let made = try FileOperations.makeFolder(named: "New", in: folder.url)
        #expect(made.lastPathComponent == "New")
        #expect(folder.has("New"))
        #expect(throws: FileOperationError.alreadyExists("New")) { try FileOperations.makeFolder(named: "New", in: folder.url) }
        #expect(throws: FileOperationError.invalidName) { try FileOperations.makeFolder(named: "a/b", in: folder.url) }
        #expect(throws: FileOperationError.invalidName) { try FileOperations.makeFolder(named: "  ", in: folder.url) }
    }

    @Test func renameMovesTheItemAndRefusesAnExistingName() throws {
        let folder = try TempFolder()
        let original = try folder.file("old.txt", "x")
        try folder.file("taken.txt")
        let renamed = try FileOperations.rename(original, to: "new.txt")
        #expect(renamed.lastPathComponent == "new.txt")
        #expect(folder.has("new.txt"))
        #expect(!folder.has("old.txt"))
        #expect(throws: FileOperationError.alreadyExists("taken.txt")) { try FileOperations.rename(renamed, to: "taken.txt") }
    }

    @Test func renamingToTheSameNameWithDifferentCaseIsAllowed() throws {
        let folder = try TempFolder()
        let original = try folder.file("file.txt")
        let renamed = try FileOperations.rename(original, to: "FILE.txt")
        #expect(renamed.lastPathComponent == "FILE.txt")
    }

    @Test func deletePermanentlyRemovesFilesAndFolders() throws {
        let folder = try TempFolder()
        let file = try folder.file("a")
        let dir = try folder.folder("d")
        try FileOperations.deletePermanently([file, dir])
        #expect(!folder.has("a"))
        #expect(!folder.has("d"))
    }

    @Test func validateRejectsEmptySlashAndDots() {
        #expect(FileOperations.validate("ok name"))
        #expect(!FileOperations.validate(""))
        #expect(!FileOperations.validate("a/b"))
        #expect(!FileOperations.validate("."))
        #expect(!FileOperations.validate(".."))
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path Core --filter "FileBrowserModelTests|LocationsTests|FileOperationsTests"`
Expected: `cannot find 'FileBrowserModel' in scope`.

- [ ] **Step 3: Implement** — `FileBrowser.swift`

```swift
import Foundation
import Observation

public struct FileEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let modified: Date
    public let isHidden: Bool

    public var id: URL { url }

    public init(url: URL, name: String, isFolder: Bool, size: Int64, modified: Date, isHidden: Bool) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
    }
}

public enum FileSortKey: Sendable, Equatable {
    case name, size, modified
}

public struct FileSort: Sendable, Equatable {
    public var key: FileSortKey
    public var ascending: Bool

    public init(key: FileSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }
}

public enum FileSorter {
    /// Folders always come first; ties fall back to the name.
    public static func sorted(_ entries: [FileEntry], by sort: FileSort) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            var order: ComparisonResult
            switch sort.key {
            case .name: order = a.name.localizedStandardCompare(b.name)
            case .size: order = a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
            case .modified: order = a.modified.compare(b.modified)
            }
            if order == .orderedSame { order = a.name.localizedStandardCompare(b.name) }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

public enum DirectoryLister {
    public static func list(_ folder: URL, access: any FileAccess, showHidden: Bool) throws -> [FileEntry] {
        var entries: [FileEntry] = []
        for url in try access.children(of: folder) {
            let name = url.lastPathComponent
            let hidden = name.hasPrefix(".")
            if hidden, !showHidden { continue }
            guard let attributes = try? access.attributes(of: url), attributes.kind != .other else { continue }
            var isFolder = attributes.kind == .directory
            if attributes.kind == .symlink {
                var directory: ObjCBool = false
                isFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            }
            entries.append(FileEntry(
                url: url, name: name, isFolder: isFolder, size: attributes.size,
                modified: attributes.modified, isHidden: hidden))
        }
        return entries
    }
}

/// One side of the two-pane view: a folder, its contents and what is selected.
@MainActor
@Observable
public final class FileBrowserModel {
    public private(set) var folder: URL
    public private(set) var entries: [FileEntry] = []
    public private(set) var errorMessage: String?
    public private(set) var freeBytes: Int64?
    public private(set) var isLoading = false
    public var selection: Set<URL> = []
    public var sort = FileSort(key: .name, ascending: true) {
        didSet { entries = FileSorter.sorted(entries, by: sort) }
    }
    public var showsHidden = false {
        didSet { Task { await reload() } }
    }

    @ObservationIgnored private var back: [URL] = []
    @ObservationIgnored private var forward: [URL] = []
    @ObservationIgnored private let access: any FileAccess
    @ObservationIgnored private var generation = 0

    public init(folder: URL, access: any FileAccess = PosixFileAccess()) {
        self.folder = folder
        self.access = access
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public var canGoUp: Bool { folder.standardizedFileURL.path != "/" }
    public var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.url) } }

    public func open(_ url: URL) {
        guard url.standardizedFileURL != folder.standardizedFileURL else { return }
        back.append(folder)
        forward.removeAll()
        show(url)
    }

    public func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(folder)
        show(previous)
    }

    public func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(folder)
        show(next)
    }

    public func goUp() { open(folder.deletingLastPathComponent()) }

    private func show(_ url: URL) {
        folder = url
        selection = []
        Task { await reload() }
    }

    /// Lists the folder again. A newer call makes an older one that is still running give up.
    public func reload() async {
        generation += 1
        let mine = generation
        isLoading = true
        let (folder, showsHidden, access) = (self.folder, self.showsHidden, self.access)
        let result = await Task.detached { () -> Result<([FileEntry], Int64?), any Error> in
            Result {
                let listed = try DirectoryLister.list(folder, access: access, showHidden: showsHidden)
                return (listed, try? access.volumeInfo(at: folder).freeBytes)
            }
        }.value
        guard mine == generation else { return }
        isLoading = false
        switch result {
        case .success(let (listed, free)):
            entries = FileSorter.sorted(listed, by: sort)
            errorMessage = nil
            freeBytes = free
            selection = selection.intersection(Set(listed.map(\.url)))
        case .failure(let error):
            entries = []
            errorMessage = error.localizedDescription
            freeBytes = nil
            selection = []
        }
    }
}

public struct FileLocation: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public let symbol: String

    public var id: URL { url }

    public init(name: String, url: URL, symbol: String) {
        self.name = name
        self.url = url
        self.symbol = symbol
    }
}

public enum Locations {
    /// Home and its usual folders, then every visible volume. Names are the system's own, already localized.
    public static func available(fileManager: FileManager = .default) -> [FileLocation] {
        var places: [FileLocation] = []
        let home = fileManager.homeDirectoryForCurrentUser
        places.append(FileLocation(name: fileManager.displayName(atPath: home.path), url: home, symbol: "house"))
        let folders: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"),
            (.documentDirectory, "doc"),
            (.downloadsDirectory, "arrow.down.circle"),
        ]
        for (directory, symbol) in folders {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                places.append(FileLocation(name: fileManager.displayName(atPath: url.path), url: url, symbol: symbol))
            }
        }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        for url in fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            let symbol = values?.volumeIsInternal == false ? "externaldrive" : "internaldrive"
            places.append(FileLocation(name: name, url: url, symbol: symbol))
        }
        return places
    }

    /// The place whose path is the longest prefix of `url`, matching whole path components.
    public static func containing(_ url: URL, in locations: [FileLocation]) -> FileLocation? {
        let path = url.standardizedFileURL.path
        return locations
            .filter { location in
                let base = location.url.standardizedFileURL.path
                return path == base || base == "/" || path.hasPrefix(base + "/")
            }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
    }
}

public enum FileOperationError: Error, Equatable {
    case invalidName
    case alreadyExists(String)
}

public enum FileOperations {
    public static func validate(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    @discardableResult
    public static func makeFolder(named name: String, in folder: URL) throws -> URL {
        guard validate(name) else { throw FileOperationError.invalidName }
        let url = folder.appending(component: name)
        if FileManager.default.fileExists(atPath: url.path) { throw FileOperationError.alreadyExists(name) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        guard validate(name) else { throw FileOperationError.invalidName }
        let target = url.deletingLastPathComponent().appending(component: name)
        let onlyCaseChanges = target.path.lowercased() == url.path.lowercased()
        if !onlyCaseChanges, FileManager.default.fileExists(atPath: target.path) {
            throw FileOperationError.alreadyExists(name)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Moves items to the Trash and returns the ones that could not go there, such as items on a volume without a Trash.
    public static func trash(_ urls: [URL]) -> [URL] {
        urls.filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) == nil }
    }

    public static func deletePermanently(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.removeItem(at: url) }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path Core --filter "FileBrowserModelTests|LocationsTests|FileOperationsTests"`
Expected: 6 + 2 + 5 tests pass. The `/private/var` vs `/var` difference is why navigation tests compare with `standardizedFileURL`.

- [ ] **Step 5: Run the whole package suite**

Run: `swift test --package-path Core --filter NTFSTransferTests`
Expected: every test in the target passes (about 80).

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/NTFSTransfer Core/Tests/NTFSTransferTests
git commit -m "Add folder browsing, locations and file operations for the two panes." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 8: Link the package into the app; text, session, Beta badge

**Files:**
- Modify: `NTFSForMac.xcodeproj/project.pbxproj` (through the script)
- Create: `App/Transfer/TransferText.swift`
- Create: `App/Transfer/TransferSession.swift`
- Create: `AppTests/TransferTextTests.swift`
- Modify: `App/Views/Main/Components.swift` (append `BetaBadge`)
- Modify: `App/AppModel.swift`

**Interfaces:**
- Consumes: the whole `NTFSTransfer` API.
- Produces: `TransferText` (`failure(_:)`, `problems(_:)`, `notice(for:stop:)`, `size(_:)`, `rate(_:)`, `duration(_:)`), `TransferPane`, `NamePrompt`, `PendingTransfer`, `TransferSession` (see below), `BetaBadge`, `AppModel.transfer`.

- [ ] **Step 1: Link the product and register the new files**

Run:
```bash
scripts/xcode-add.py product NTFSTransfer
scripts/xcode-add.py file App/Transfer/TransferText.swift App/Transfer/TransferSession.swift AppTests/TransferTextTests.swift
git diff --stat NTFSForMac.xcodeproj
```
Expected: `project.pbxproj` changes only by added lines. The files do not exist yet, so do not build until Step 5.

- [ ] **Step 2: Write the failing test** — `AppTests/TransferTextTests.swift`

```swift
import Foundation
import NTFSTransfer
import Testing
@testable import NTFS_for_Mac

struct TransferTextTests {
    @Test func everyFailureReasonHasAMessage() {
        let reasons: [TransferFailureReason] = [
            .unreadable, .writeFailed, .noSpace, .driveRemoved, .permissionDenied,
            .invalidName, .checksumMismatch, .sizeMismatch, .sourceMissing, .conflictingKind,
        ]
        for reason in reasons {
            #expect(!TransferText.failure(reason).isEmpty)
        }
    }

    @Test func aCleanFinishSaysTheCountSizeAndTime() {
        let summary = TransferSummary(copied: 14, failed: 0, skipped: 0, bytes: 5_000_000_000, duration: 252)
        let notice = TransferText.notice(for: summary, stop: .finished)
        #expect(notice.title == "Copy complete")
        #expect(notice.body.contains("14"))
    }

    @Test func failuresChangeTheTitleAndMentionTheCount() {
        let summary = TransferSummary(copied: 12, failed: 2, skipped: 0, bytes: 1000, duration: 5)
        let notice = TransferText.notice(for: summary, stop: .finished)
        #expect(notice.title == "Copy finished with errors")
        #expect(notice.body.contains("12"))
        #expect(notice.body.contains("2"))
    }

    @Test func eachStopReasonHasItsOwnTitle() {
        let summary = TransferSummary(copied: 1, failed: 0, skipped: 1, bytes: 1, duration: 1)
        let titles = [TransferStop.cancelled, .noSpace, .driveRemoved, .userStopped]
            .map { TransferText.notice(for: summary, stop: $0).title }
        #expect(Set(titles).count == 4)
    }

    @Test func problemsListTheFirstFiveAndCountTheRest() {
        let problems = (0..<8).map { TransferProblem.invalidName(job: $0, name: "bad\($0):") }
        let text = TransferText.problems(problems)
        #expect(text.contains("bad0:"))
        #expect(text.contains("bad4:"))
        #expect(!text.contains("bad5:"))
        #expect(text.contains("3"))
    }

    @Test func spaceProblemsMentionBothSizes() {
        let text = TransferText.problems([.notEnoughSpace(needed: 2_000_000_000, available: 1_000_000_000)])
        #expect(text.contains(TransferText.size(2_000_000_000)))
        #expect(text.contains(TransferText.size(1_000_000_000)))
    }

    @Test func ratesAndDurationsAreReadable() {
        #expect(TransferText.rate(100_000_000).hasSuffix("/s"))
        #expect(!TransferText.duration(252).isEmpty)
    }
}
```

- [ ] **Step 3: Implement `App/Transfer/TransferText.swift`**

```swift
import Foundation
import NTFSTransfer

/// The words the transfer screens use. The package reports reasons; this turns them into text.
enum TransferText {
    static func failure(_ reason: TransferFailureReason) -> String {
        switch reason {
        case .unreadable: String(localized: "Can't read this file. It may be damaged.")
        case .writeFailed: String(localized: "Couldn't write to the destination.")
        case .noSpace: String(localized: "The destination is full.")
        case .driveRemoved: String(localized: "The drive was disconnected.")
        case .permissionDenied: String(localized: "No permission to read or write here.")
        case .invalidName: String(localized: "The name isn't allowed on the destination.")
        case .checksumMismatch: String(localized: "The copy didn't match the original.")
        case .sizeMismatch: String(localized: "The file changed while copying.")
        case .sourceMissing: String(localized: "The file was removed before it could be copied.")
        case .conflictingKind: String(localized: "A folder and a file have the same name.")
        }
    }

    static func problems(_ problems: [TransferProblem]) -> String {
        var lines: [String] = []
        for problem in problems where problem.isBlocking {
            if case .notEnoughSpace(let needed, let available) = problem {
                lines.append(String(localized: "Not enough space on the destination. Needed \(size(needed)), available \(size(available))."))
            }
        }
        let others = problems.filter { !$0.isBlocking }
        for problem in others.prefix(5) {
            switch problem {
            case .invalidName(_, let name):
                lines.append(String(localized: "“\(name)” can't be stored on this drive: the name isn't allowed."))
            case .fileTooLarge(_, let name):
                lines.append(String(localized: "“\(name)” is too large for this drive's file system."))
            case .notEnoughSpace:
                break
            }
        }
        if others.count > 5 {
            lines.append(String(localized: "…and \(others.count - 5) more"))
        }
        return lines.joined(separator: "\n")
    }

    static func notice(for summary: TransferSummary, stop: TransferStop) -> (title: String, body: String) {
        switch stop {
        case .finished where summary.failed == 0:
            (String(localized: "Copy complete"),
             String(localized: "Files copied: \(summary.copied) · \(size(summary.bytes)) · \(duration(summary.duration))"))
        case .finished:
            (String(localized: "Copy finished with errors"),
             String(localized: "Files copied: \(summary.copied) · Failed: \(summary.failed)"))
        case .cancelled:
            (String(localized: "Copy cancelled"),
             String(localized: "Files copied: \(summary.copied) · Skipped: \(summary.skipped)"))
        case .noSpace:
            (String(localized: "The destination is full"),
             String(localized: "Free some space, then resume the copy."))
        case .driveRemoved:
            (String(localized: "A drive was disconnected"),
             String(localized: "Reconnect it, then resume the copy."))
        case .userStopped:
            (String(localized: "Copy stopped"),
             String(localized: "Files copied: \(summary.copied) · Failed: \(summary.failed)"))
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(size(Int64(bytesPerSecond)))/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
```

- [ ] **Step 4: Implement `App/Transfer/TransferSession.swift`**

```swift
import AppKit
import NTFSTransfer
import Observation

enum TransferPane {
    case left, right

    var other: TransferPane { self == .left ? .right : .left }
}

struct NamePrompt: Identifiable {
    enum Kind { case newFolder, rename(URL) }

    let id = UUID()
    let kind: Kind
}

/// A plan that has problems the person must decide about before anything is copied.
struct PendingTransfer: Identifiable {
    let id = UUID()
    let jobs: [TransferJob]
    let problems: [TransferProblem]

    var isBlocked: Bool { problems.contains { $0.isBlocking } }
    var restOfJobs: [TransferJob] { TransferPreflight.jobs(jobs, without: problems) }
}

/// Owns everything behind the File Transfer page: the two panes, the queue, and the app-level extras.
@MainActor
@Observable
final class TransferSession {
    static let verifyKey = "TransferVerify"
    static let askOnErrorKey = "TransferAskOnError"
    static let preventSleepKey = "TransferPreventSleep"

    let queue = TransferQueue()
    let left: FileBrowserModel
    let right: FileBrowserModel
    var activePane: TransferPane = .left
    private(set) var locations = Locations.available()

    var namePrompt: NamePrompt?
    var promptText = ""
    var deleteRequest: [URL]?
    var pendingTransfer: PendingTransfer?
    var previewURL: URL?
    var alertMessage: String?

    @ObservationIgnored private let notify: @MainActor (String, String) -> Void
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var lastBadgePercent = -1

    init(notify: @escaping @MainActor (String, String) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        left = FileBrowserModel(folder: home)
        right = FileBrowserModel(folder: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home)
        self.notify = notify
        UserDefaults.standard.register(defaults: [Self.preventSleepKey: true])
        queue.onProgress = { [weak self] progress in self?.progressChanged(progress) }
        queue.onFinish = { [weak self] summary, stop in self?.finished(summary, stop) }
    }

    func model(for pane: TransferPane) -> FileBrowserModel { pane == .left ? left : right }
    var activeModel: FileBrowserModel { model(for: activePane) }
    var otherModel: FileBrowserModel { model(for: activePane.other) }

    func refreshLocations() { locations = Locations.available() }

    // MARK: Toolbar state

    var canCopy: Bool { !activeModel.selection.isEmpty }
    var canRename: Bool { activeModel.selection.count == 1 }
    var canDelete: Bool { !activeModel.selection.isEmpty }
    var canPreview: Bool { !activeModel.selection.isEmpty }

    // MARK: Copying

    func copyActiveToOther() {
        copy(activeModel.selectedEntries.map(\.url), into: otherModel.folder)
    }

    /// Dropping one row of a multi-selection brings the whole selection along.
    func drop(_ urls: [URL], onto pane: TransferPane) {
        var sources = urls
        let origin = model(for: pane.other)
        if urls.count == 1, origin.selection.contains(urls[0]) {
            sources = origin.selectedEntries.map(\.url)
        }
        copy(sources, into: model(for: pane).folder)
    }

    func copy(_ sources: [URL], into destination: URL) {
        guard !sources.isEmpty else { return }
        Task {
            let access = PosixFileAccess()
            do {
                let planned = try await Task.detached(priority: .userInitiated) { () throws -> ([TransferJob], VolumeInfo) in
                    let jobs = try TransferPlanner.plan(sources: sources, into: destination, access: access)
                    return (jobs, try access.volumeInfo(at: destination))
                }.value
                let rules = DestinationRules.forFileSystem(planned.1.fileSystemType)
                let problems = TransferPreflight.check(jobs: planned.0, rules: rules, freeBytes: planned.1.freeBytes)
                if problems.isEmpty {
                    start(planned.0)
                } else {
                    pendingTransfer = PendingTransfer(jobs: planned.0, problems: problems)
                }
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    func start(_ jobs: [TransferJob]) {
        let defaults = UserDefaults.standard
        queue.options = TransferOptions(
            verify: defaults.bool(forKey: Self.verifyKey),
            askOnError: defaults.bool(forKey: Self.askOnErrorKey))
        if activity == nil, defaults.bool(forKey: Self.preventSleepKey) {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Copying files")
        }
        queue.enqueue(jobs)
    }

    func pasteFromPasteboard(into pane: TransferPane) {
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        copy(urls, into: model(for: pane).folder)
    }

    func copyProviders(for pane: TransferPane) -> [NSItemProvider] {
        model(for: pane).selectedEntries.map { NSItemProvider(object: $0.url as NSURL) }
    }

    // MARK: Progress and finish

    private func progressChanged(_ progress: TransferProgress) {
        let percent = Int(progress.fraction * 100)
        guard percent != lastBadgePercent else { return }
        lastBadgePercent = percent
        NSApp?.dockTile.badgeLabel = queue.isBusy ? "\(percent)%" : nil
    }

    private func finished(_ summary: TransferSummary, _ stop: TransferStop) {
        endActivity()
        lastBadgePercent = -1
        NSApp?.dockTile.badgeLabel = nil
        let notice = TransferText.notice(for: summary, stop: stop)
        notify(notice.title, notice.body)
        Task {
            await left.reload()
            await right.reload()
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func exportFailures() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Transfer errors.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = queue.progress.failedItems.map { item in
            let reason = item.failure.map { TransferText.failure($0.reason) } ?? ""
            let detail = item.failure?.detail ?? ""
            return "\(item.job.source.path)\t\(reason)\t\(detail)"
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Files

    func beginNewFolder() {
        promptText = String(localized: "untitled folder")
        namePrompt = NamePrompt(kind: .newFolder)
    }

    func beginRename() {
        guard activeModel.selection.count == 1, let entry = activeModel.selectedEntries.first else { return }
        promptText = entry.name
        namePrompt = NamePrompt(kind: .rename(entry.url))
    }

    func commitNamePrompt() {
        guard let prompt = namePrompt else { return }
        namePrompt = nil
        let model = activeModel
        do {
            let created: URL
            switch prompt.kind {
            case .newFolder: created = try FileOperations.makeFolder(named: promptText, in: model.folder)
            case .rename(let url): created = try FileOperations.rename(url, to: promptText)
            }
            Task {
                await model.reload()
                model.selection = [created]
            }
        } catch {
            alertMessage = Self.message(for: error)
        }
    }

    func requestDelete() {
        let model = activeModel
        let urls = model.selectedEntries.map(\.url)
        guard !urls.isEmpty else { return }
        let stuck = FileOperations.trash(urls)
        Task { await model.reload() }
        if !stuck.isEmpty { deleteRequest = stuck }
    }

    func confirmDelete() {
        guard let urls = deleteRequest else { return }
        deleteRequest = nil
        let model = activeModel
        do {
            try FileOperations.deletePermanently(urls)
        } catch {
            alertMessage = error.localizedDescription
        }
        Task { await model.reload() }
    }

    func preview() {
        previewURL = activeModel.selectedEntries.first?.url
    }

    func revealInFinder() {
        let urls = activeModel.selectedEntries.map(\.url)
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([activeModel.folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case TransferPlanner.PlanError.destinationInsideSource:
            String(localized: "A folder can't be copied into itself.")
        case FileOperationError.invalidName:
            String(localized: "That name can't be used.")
        case FileOperationError.alreadyExists(let name):
            String(localized: "An item named “\(name)” already exists.")
        default:
            error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Add the Beta badge and the session to the app**

Append to `App/Views/Main/Components.swift`:

```swift
/// Marks a feature that is still being tested.
struct BetaBadge: View {
    var body: some View {
        Text(verbatim: "BETA")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(.orange)
            .background(.orange.opacity(0.2), in: .capsule)
            .accessibilityLabel("Beta")
    }
}
```

In `App/AppModel.swift`, after the line `let updates = AppUpdater()`, add:

```swift
    /// The two-sided file copy page.
    @ObservationIgnored private(set) lazy var transfer = TransferSession { [notifier] title, body in
        notifier.post(title: title, body: body)
    }
```

- [ ] **Step 6: Build and run the app tests**

Run: `xcodebuild -scheme NTFSForMac -only-testing:NTFSForMacTests CODE_SIGNING_ALLOWED=NO test 2>&1 | rg "Test run with|TEST SUCCEEDED|TEST FAILED|error:|✘"`
Expected: `TEST SUCCEEDED`, the earlier 113 tests plus the 7 `TransferTextTests`. The Vietnamese translations come in Task 12; the tests run in English.

- [ ] **Step 7: Commit**

```bash
git add NTFSForMac.xcodeproj App AppTests
git commit -m "Link the transfer package into the app and add the session, text and Beta badge." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 9: Sidebar entry, routing and toolbar

**Files:**
- Create: `App/Transfer/TransferPage.swift` (a minimal page for now; filled in by Tasks 10 and 11)
- Modify: `App/Views/Main/SidebarView.swift`
- Modify: `App/Views/Main/MainWindowView.swift`

**Interfaces:**
- Consumes: `TransferSession`, `BetaBadge`.
- Produces: `SidebarSelection.transfer`, `TransferPage(session:)`.

- [ ] **Step 1: Register and create a placeholder page**

Run `scripts/xcode-add.py file App/Transfer/TransferPage.swift`, then create `App/Transfer/TransferPage.swift`:

```swift
import SwiftUI

struct TransferPage: View {
    @Bindable var session: TransferSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("File Transfer").font(.title3.weight(.semibold))
                BetaBadge()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Spacer()
        }
    }
}
```

- [ ] **Step 2: Sidebar** — in `App/Views/Main/SidebarView.swift`:

Replace
```swift
enum SidebarSelection: Hashable {
    case disk(String)
    case partition(String)
    case settings
}
```
with
```swift
enum SidebarSelection: Hashable {
    case disk(String)
    case partition(String)
    case settings
    case transfer
}
```

Replace
```swift
        List(selection: $selection) {
            if disks.isEmpty {
```
with
```swift
        List(selection: $selection) {
            Section {
                HStack {
                    Label("File Transfer", systemImage: "arrow.left.arrow.right")
                    Spacer()
                    if model.transfer.queue.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    BetaBadge()
                }
                .tag(SidebarSelection.transfer)
            }
            if disks.isEmpty {
```

- [ ] **Step 3: Routing and toolbar** — in `App/Views/Main/MainWindowView.swift`:

Replace
```swift
        if selection == .settings {
            SettingsView(model: model)
        } else if let found = selectedPartition {
```
with
```swift
        if selection == .transfer {
            TransferPage(session: model.transfer)
        } else if selection == .settings {
            SettingsView(model: model)
        } else if let found = selectedPartition {
```

Replace
```swift
    /// The same four buttons on every page, dimmed when they don't apply, so the
    /// toolbar keeps one height and one layout like Disk Utility's.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let found = selectedPartition, found.partition.mount != nil {
```
with
```swift
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selection == .transfer {
            transferToolbar
        } else {
            driveToolbar
        }
    }

    /// The file copy page has its own buttons, in the same style and height.
    @ToolbarContentBuilder
    private var transferToolbar: some ToolbarContent {
        actionItem(
            "Copy", systemImage: "doc.on.doc",
            help: String(localized: "Copy the selection to the other side"),
            disabled: !model.transfer.canCopy
        ) { model.transfer.copyActiveToOther() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("New Folder", systemImage: "folder.badge.plus") { model.transfer.beginNewFolder() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Rename", systemImage: "pencil", disabled: !model.transfer.canRename) { model.transfer.beginRename() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Delete", systemImage: "trash", disabled: !model.transfer.canDelete) { model.transfer.requestDelete() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Quick Look", systemImage: "eye", disabled: !model.transfer.canPreview) { model.transfer.preview() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Finder", systemImage: "folder", help: String(localized: "Show in Finder")) { model.transfer.revealInFinder() }
    }

    /// The same four buttons on every drive page, dimmed when they don't apply, so the
    /// toolbar keeps one height and one layout like Disk Utility's.
    @ToolbarContentBuilder
    private var driveToolbar: some ToolbarContent {
        if let found = selectedPartition, found.partition.mount != nil {
```

In `currentFormatTarget`, `selectedDisk` and `keepSelectionValid` update the three switches:

```swift
        case .settings?, nil: nil
```
(in `currentFormatTarget`) becomes
```swift
        case .settings?, .transfer?, nil: nil
```
and in `selectedDisk` the same line `case .settings?, nil: nil` becomes `case .settings?, .transfer?, nil: nil`. In `keepSelectionValid`, `case .settings?: true` becomes `case .settings?, .transfer?: true`.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme NTFSForMac -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | rg "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add NTFSForMac.xcodeproj App
git commit -m "Add the File Transfer row with its Beta badge and the page's own toolbar." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 10: The two panes

**Files:**
- Create: `App/Transfer/FilePaneView.swift`
- Modify: `App/Transfer/TransferPage.swift`

**Interfaces:**
- Consumes: `TransferSession`, `FileBrowserModel`, `FileEntry`, `Locations`.
- Produces: `FilePaneView(session:pane:)`; the page lays out two panes and the Beta notice.

- [ ] **Step 1: Register and create `App/Transfer/FilePaneView.swift`** (`scripts/xcode-add.py file App/Transfer/FilePaneView.swift`)

```swift
import NTFSTransfer
import SwiftUI

/// One side of the page: where you are, what's there, and what's selected.
struct FilePaneView: View {
    @Bindable var session: TransferSession
    let pane: TransferPane
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name)]
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = session.model(for: pane)
        let isActive = session.activePane == pane
        VStack(spacing: 0) {
            header(model)
                .overlay(alignment: .top) {
                    if isActive { Color.accentColor.frame(height: 2) }
                }
            Divider()
            table(model: model)
            Divider()
            footer(model)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.drop(urls, onto: pane)
            return true
        } isTargeted: { isTargeted = $0 }
        .simultaneousGesture(TapGesture().onEnded { session.activePane = pane })
    }

    // MARK: Header

    private func header(_ model: FileBrowserModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!model.canGoUp)
                    .help("Enclosing Folder")
                locationMenu(model)
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            Text(model.folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func locationMenu(_ model: FileBrowserModel) -> some View {
        let current = Locations.containing(model.folder, in: session.locations)
        return Menu {
            ForEach(session.locations) { location in
                Button { model.open(location.url) } label: {
                    Label(location.name, systemImage: location.symbol)
                }
            }
        } label: {
            Label(current?.name ?? model.folder.lastPathComponent, systemImage: current?.symbol ?? "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Table

    private func table(model: FileBrowserModel) -> some View {
        @Bindable var model = model
        return Table(of: FileEntry.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1)
                } icon: {
                    Image(systemName: entry.isFolder ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                }
            }
            TableColumn("Size", value: \.size) { entry in
                Text(entry.isFolder ? "—" : TransferText.size(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("Date Modified", value: \.modified) { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140, max: 190)
        } rows: {
            ForEach(model.entries) { entry in
                TableRow(entry).draggable(entry.url)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            menu(for: urls)
        } primaryAction: { urls in
            open(urls, in: model)
        }
        .onChange(of: sortOrder) { _, comparators in
            model.sort = FileSort(comparators: comparators)
        }
        .onChange(of: model.selection) { _, selection in
            if !selection.isEmpty { session.activePane = pane }
        }
        .onCopyCommand { session.copyProviders(for: pane) }
        .onPasteCommand(of: [.fileURL]) { _ in session.pasteFromPasteboard(into: pane) }
        .onDeleteCommand {
            session.activePane = pane
            session.requestDelete()
        }
        .onKeyPress(.space) {
            session.activePane = pane
            session.preview()
            return .handled
        }
        .overlay {
            if let message = model.errorMessage {
                ContentUnavailableView(
                    "Can't open this folder", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            } else if model.entries.isEmpty, !model.isLoading {
                Text("This folder is empty").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for urls: Set<URL>) -> some View {
        if !urls.isEmpty {
            Button("Open") { open(Array(urls), in: session.model(for: pane)) }
            Button("Copy to the Other Side") {
                session.activePane = pane
                session.copyActiveToOther()
            }
            Button("Quick Look") {
                session.activePane = pane
                session.preview()
            }
            if urls.count == 1 {
                Button("Rename") {
                    session.activePane = pane
                    session.beginRename()
                }
            }
            Button("Move to Trash") {
                session.activePane = pane
                session.requestDelete()
            }
            Button("Show in Finder") {
                session.activePane = pane
                session.revealInFinder()
            }
        }
        Button("New Folder") {
            session.activePane = pane
            session.beginNewFolder()
        }
    }

    private func open(_ urls: some Collection<URL>, in model: FileBrowserModel) {
        if urls.count == 1, let url = urls.first, let entry = model.entries.first(where: { $0.url == url }), entry.isFolder {
            model.open(url)
            return
        }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    // MARK: Footer

    private func footer(_ model: FileBrowserModel) -> some View {
        HStack {
            if model.selection.isEmpty {
                if let free = model.freeBytes {
                    Text("Items: \(model.entries.count) · \(TransferText.size(free)) free")
                } else {
                    Text("Items: \(model.entries.count)")
                }
            } else {
                let size = model.selectedEntries.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }
                Text("Selected: \(model.selection.count) · \(TransferText.size(size))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private extension FileSort {
    /// Table column headers produce comparators; the model sorts with its own key and direction.
    init(comparators: [KeyPathComparator<FileEntry>]) {
        guard let first = comparators.first else {
            self.init(key: .name, ascending: true)
            return
        }
        let size: PartialKeyPath<FileEntry> = \FileEntry.size
        let modified: PartialKeyPath<FileEntry> = \FileEntry.modified
        let key: FileSortKey = first.keyPath == size ? .size : (first.keyPath == modified ? .modified : .name)
        self.init(key: key, ascending: first.order == .forward)
    }
}
```

- [ ] **Step 2: Lay the panes out in the page** — replace the whole of `App/Transfer/TransferPage.swift` with:

```swift
import NTFSTransfer
import SwiftUI

struct TransferPage: View {
    @Bindable var session: TransferSession
    @AppStorage("TransferBetaNoticeDismissed") private var noticeDismissed = false
    /// Below this width the two sides stack instead of sitting side by side.
    private static let stackWidth: CGFloat = 900
    @State private var stacked = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !noticeDismissed { betaNotice }
            Divider()
            panes
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.stackWidth }) { stacked = $0 }
        .task {
            await session.left.reload()
            await session.right.reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            session.refreshLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            session.refreshLocations()
        }
        .quickLookPreview($session.previewURL)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("File Transfer").font(.title3.weight(.semibold))
            BetaBadge()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var betaNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text("File Transfer is in beta. Keep a second copy of anything important.")
                .font(.callout)
            Spacer()
            Button {
                noticeDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    @ViewBuilder
    private var panes: some View {
        if stacked {
            VSplitView {
                FilePaneView(session: session, pane: .left).frame(minHeight: 140)
                FilePaneView(session: session, pane: .right).frame(minHeight: 140)
            }
        } else {
            HSplitView {
                FilePaneView(session: session, pane: .left).frame(minWidth: 280)
                FilePaneView(session: session, pane: .right).frame(minWidth: 280)
            }
        }
    }
}
```

- [ ] **Step 3: Build and look at it**

Run: `xcodebuild -scheme NTFSForMac -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | rg "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`. Then `scripts/build-local.sh`, install into `/Applications` as for earlier builds, open **File Transfer** and check by hand: both panes list folders, double-click enters a folder, the location menu switches drives, selecting rows highlights the pane, dragging a row from one pane to the other does nothing yet (the copy starts a run, but there is no panel until Task 11; the Dock icon shows the percentage and a notification appears at the end). If a drag of several selected rows moves only one, the drop handler still copies the whole selection.

- [ ] **Step 4: Commit**

```bash
git add NTFSForMac.xcodeproj App
git commit -m "Add the two file panes with drag and drop, copy and paste, and the Beta notice." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 11: Progress panel, prompts and alerts

**Files:**
- Create: `App/Transfer/TransferProgressPanel.swift`
- Create: `App/Transfer/TransferPrompts.swift`
- Modify: `App/Transfer/TransferPage.swift`

**Interfaces:**
- Consumes: `TransferQueue`, `TransferProgress`, `TransferText`, `TransferSession`.
- Produces: `TransferProgressPanel(session:)`, `ConflictSheet(request:answer:)`, `ErrorSheet(request:answer:)`.

- [ ] **Step 1: Register the files**: `scripts/xcode-add.py file App/Transfer/TransferProgressPanel.swift App/Transfer/TransferPrompts.swift`

- [ ] **Step 2: Create `App/Transfer/TransferPrompts.swift`**

```swift
import NTFSTransfer
import SwiftUI

/// Asks what to do when a file with the same name is already there.
struct ConflictSheet: View {
    let request: ConflictRequest
    let answer: (ConflictDecision) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("“\(request.info.name)” already exists")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Already there", request.info.existing)
                row("Being copied", request.info.source)
            }
            Toggle("Apply to all", isOn: $applyToAll)
            HStack {
                Button("Skip") { choose(.skip) }
                Button("Replace If Newer") { choose(.replaceIfNewer) }
                Spacer()
                Button("Keep Both") { choose(.keepBoth) }
                Button("Replace") { choose(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private func row(_ title: LocalizedStringKey, _ attributes: FileAttributes) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text("\(TransferText.size(attributes.size)) · \(attributes.modified.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private func choose(_ choice: ConflictChoice) {
        answer(ConflictDecision(choice: choice, applyToAll: applyToAll))
    }
}

/// Asks what to do after a file failed, when "Ask what to do on errors" is on.
struct ErrorSheet: View {
    let request: ErrorRequest
    let answer: (ErrorDecision) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Couldn't copy “\(request.info.name)”")
                .font(.headline)
            Text(TransferText.failure(request.info.failure.reason))
                .foregroundStyle(.secondary)
            Toggle("Apply to all", isOn: $applyToAll)
            HStack {
                Button("Stop") { choose(.stop) }
                Spacer()
                Button("Skip") { choose(.skip) }
                Button("Retry") { choose(.retry) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private func choose(_ choice: ErrorChoice) {
        answer(ErrorDecision(choice: choice, applyToAll: applyToAll))
    }
}
```

- [ ] **Step 3: Create `App/Transfer/TransferProgressPanel.swift`**

```swift
import NTFSTransfer
import SwiftUI

/// Under the two sides: how far along the copy is, how fast, which files are done, and which failed.
struct TransferProgressPanel: View {
    @Bindable var session: TransferSession
    @State private var filter = Filter.all
    @AppStorage(TransferSession.verifyKey) private var verify = false
    @AppStorage(TransferSession.askOnErrorKey) private var askOnError = false
    @AppStorage(TransferSession.preventSleepKey) private var preventSleep = true

    enum Filter: Hashable {
        case all, copying, errors
    }

    private var queue: TransferQueue { session.queue }
    private var progress: TransferProgress { queue.progress }

    var body: some View {
        VStack(spacing: 0) {
            if progress.items.isEmpty {
                empty
            } else {
                summaryBlock
                Divider()
                list
                Divider()
                footer
            }
        }
        .background(.background)
    }

    private var empty: some View {
        HStack {
            Text("Drag files between the two sides, or select files and press Copy.")
                .foregroundStyle(.secondary)
            Spacer()
            optionsMenu
        }
        .padding(12)
    }

    // MARK: Summary

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusText).font(.headline)
                Spacer()
                optionsMenu
            }
            ProgressView(value: progress.fraction)
            HStack(spacing: 12) {
                Text("\(TransferText.size(progress.processedBytes)) of \(TransferText.size(progress.totalBytes))")
                if let seconds = progress.secondsRemaining, queue.phase == .running {
                    Text("About \(TransferText.duration(seconds)) left")
                }
                if progress.readRate > 0 || progress.writeRate > 0, queue.isBusy {
                    Text("Read \(TransferText.rate(progress.readRate)) · Write \(TransferText.rate(progress.writeRate))")
                }
                Spacer()
                controls
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var statusText: String {
        switch queue.phase {
        case .idle, .running:
            String(localized: "Copying files: \(progress.doneCount) of \(progress.fileCount)")
        case .paused:
            String(localized: "Paused")
        case .stopped(let stop):
            summaryTitle(stop)
        case .finished:
            summaryTitle(.finished)
        }
    }

    private func summaryTitle(_ stop: TransferStop) -> String {
        TransferText.notice(for: queue.summary ?? progress.summary(), stop: stop).title
    }

    @ViewBuilder
    private var controls: some View {
        switch queue.phase {
        case .running:
            Button("Pause") { queue.pause() }
            Button("Skip This File") { queue.skipCurrent() }
            Button("Cancel") { queue.cancel() }
        case .paused:
            Button("Resume") { queue.resume() }
            Button("Cancel") { queue.cancel() }
        case .stopped:
            Button("Resume") { queue.resume() }
            Button("Cancel") { queue.cancel() }
        case .idle, .finished:
            EmptyView()
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Verify after copy", isOn: $verify)
            Toggle("Ask what to do on errors", isOn: $askOnError)
            Toggle("Prevent sleep while copying", isOn: $preventSleep)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: List

    private var visibleItems: [TransferItem] {
        progress.items.filter { item in
            guard !item.job.isDirectory else { return false }
            switch filter {
            case .all: return true
            case .copying: return item.state == .copying || item.state == .waiting
            case .errors: return item.failure != nil
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                Text("All").tag(Filter.all)
                Text("Copying").tag(Filter.copying)
                Text("Errors").tag(Filter.errors)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.vertical, 6)
            List(visibleItems) { item in
                TransferRow(item: item)
            }
            .listStyle(.plain)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            let failed = progress.failedItems.count
            if failed > 0 {
                Label("Errors: \(failed)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Spacer()
            if failed > 0, !queue.isBusy {
                Button("Retry Failed") { queue.retryFailed() }
            }
            if failed > 0 {
                Button("Export Error List…") { session.exportFailures() }
            }
            if queue.phase == .finished {
                Button("Clear") { queue.clear() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.job.name).lineLimit(1)
                if let failure = item.failure {
                    Text(TransferText.failure(failure.reason))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Text(TransferText.size(item.job.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            statusView.frame(width: 90, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .copying: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.state {
        case .waiting: Text("Waiting").foregroundStyle(.secondary)
        case .copying:
            if item.job.size > 0 {
                Text(Double(item.bytesDone) / Double(item.job.size), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            } else {
                Text("Copying")
            }
        case .done: Text("Done").foregroundStyle(.secondary)
        case .failed: Text("Failed").foregroundStyle(.red)
        case .skipped: Text("Skipped").foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: Put the panel, sheets and alerts into the page** — in `App/Transfer/TransferPage.swift` replace the `body` with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            header
            if !noticeDismissed { betaNotice }
            Divider()
            VSplitView {
                panes.frame(minHeight: 240)
                TransferProgressPanel(session: session).frame(minHeight: 120, idealHeight: 240)
            }
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.stackWidth }) { stacked = $0 }
        .task {
            await session.left.reload()
            await session.right.reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            session.refreshLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            session.refreshLocations()
        }
        .quickLookPreview($session.previewURL)
        .sheet(item: Binding(get: { session.queue.conflict }, set: { _ in })) { request in
            ConflictSheet(request: request) { session.queue.answer($0) }
        }
        .sheet(item: Binding(get: { session.queue.errorPrompt }, set: { _ in })) { request in
            ErrorSheet(request: request) { session.queue.answerError($0) }
        }
        .alert(
            namePromptTitle,
            isPresented: Binding(get: { session.namePrompt != nil }, set: { if !$0 { session.namePrompt = nil } })
        ) {
            TextField("Name", text: $session.promptText)
            Button("Cancel", role: .cancel) {}
            Button(namePromptButton) { session.commitNamePrompt() }
        }
        .alert(
            "Can't copy everything",
            isPresented: Binding(get: { session.pendingTransfer != nil }, set: { if !$0 { session.pendingTransfer = nil } }),
            presenting: session.pendingTransfer
        ) { pending in
            if !pending.isBlocked, !pending.restOfJobs.isEmpty {
                Button("Copy the Rest") { session.start(pending.restOfJobs) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(TransferText.problems(pending.problems))
        }
        .alert(
            "Delete permanently?",
            isPresented: Binding(get: { session.deleteRequest != nil }, set: { if !$0 { session.deleteRequest = nil } })
        ) {
            Button("Delete", role: .destructive) { session.confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These items can't be moved to the Trash. They will be deleted permanently.")
        }
        .alert(
            "File Transfer",
            isPresented: Binding(get: { session.alertMessage != nil }, set: { if !$0 { session.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(session.alertMessage ?? "")
        }
    }

    private var namePromptTitle: LocalizedStringKey {
        if case .rename? = session.namePrompt?.kind { "Rename" } else { "New Folder" }
    }

    private var namePromptButton: LocalizedStringKey {
        if case .rename? = session.namePrompt?.kind { "Rename" } else { "Create" }
    }
```

- [ ] **Step 5: Build, install, and check by hand**

Run: `xcodebuild -scheme NTFSForMac -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | rg "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `BUILD SUCCEEDED`. If `.alert(... presenting:)` or the `if case .rename?` pattern does not compile, replace the pattern with `session.namePrompt.map { if case .rename = $0.kind { true } else { false } } ?? false`.

Then `scripts/build-local.sh`, reinstall, and run through the manual list in Task 13.

- [ ] **Step 6: Commit**

```bash
git add NTFSForMac.xcodeproj App
git commit -m "Add the progress panel, conflict and error prompts, and the page's alerts." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 12: Menu status, quitting safely, Vietnamese strings

**Files:**
- Modify: `App/Views/MenuContentView.swift`
- Modify: `App/NTFSForMacApp.swift`
- Modify: `App/Localizable.xcstrings`

- [ ] **Step 1: Menu bar status line** — in `App/Views/MenuContentView.swift` replace

```swift
            Divider()

            Button {
                windows.showMain()
```
with
```swift
            if model.transfer.queue.isBusy {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Copying files…")
                    Text(model.transfer.queue.progress.fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                windows.showMain()
```

- [ ] **Step 2: Confirm before quitting during a copy** — in `App/NTFSForMacApp.swift` replace

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isFormatting else { return .terminateNow }
        WindowPresenter.showFormattingInProgress()
        return .terminateCancel
    }
```
with
```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isFormatting {
            WindowPresenter.showFormattingInProgress()
            return .terminateCancel
        }
        guard model.transfer.queue.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Files are still being copied")
        alert.informativeText = String(localized: "Quitting now cancels the copy and removes the unfinished files.")
        alert.addButton(withTitle: String(localized: "Keep Copying"))
        alert.addButton(withTitle: String(localized: "Quit"))
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        Task {
            await model.transfer.queue.cancelAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
```

- [ ] **Step 3: Add the Vietnamese strings** — create a throwaway script `/tmp/add-strings.py` (not committed) and run it from the repo root. It adds only keys that are not in the catalog yet and keeps the file's existing order:

```python
import json

PATH = "App/Localizable.xcstrings"
NEW = {
    "Can't read this file. It may be damaged.": "Không đọc được tệp này. Tệp có thể bị hỏng.",
    "Couldn't write to the destination.": "Không ghi được vào nơi đến.",
    "The destination is full.": "Nơi đến đã đầy.",
    "The drive was disconnected.": "Ổ đã bị ngắt kết nối.",
    "No permission to read or write here.": "Không có quyền đọc hoặc ghi ở đây.",
    "The name isn't allowed on the destination.": "Tên này không được phép trên nơi đến.",
    "The copy didn't match the original.": "Bản sao không khớp với bản gốc.",
    "The file changed while copying.": "Tệp đã thay đổi trong lúc sao chép.",
    "The file was removed before it could be copied.": "Tệp đã bị xoá trước khi kịp sao chép.",
    "A folder and a file have the same name.": "Một thư mục và một tệp trùng tên.",
    "Copy complete": "Đã sao chép xong",
    "Files copied: %lld · %@ · %@": "Đã sao chép: %lld tệp · %@ · %@",
    "Copy finished with errors": "Sao chép xong nhưng có lỗi",
    "Files copied: %lld · Failed: %lld": "Đã sao chép: %lld tệp · Lỗi: %lld",
    "Copy cancelled": "Đã huỷ sao chép",
    "Files copied: %lld · Skipped: %lld": "Đã sao chép: %lld tệp · Bỏ qua: %lld",
    "The destination is full": "Nơi đến đã đầy",
    "Free some space, then resume the copy.": "Hãy giải phóng dung lượng rồi tiếp tục sao chép.",
    "A drive was disconnected": "Một ổ đã bị ngắt kết nối",
    "Reconnect it, then resume the copy.": "Hãy cắm lại ổ rồi tiếp tục sao chép.",
    "Copy stopped": "Đã dừng sao chép",
    "Not enough space on the destination. Needed %@, available %@.": "Nơi đến không đủ dung lượng. Cần %1$@, còn %2$@.",
    "“%@” can't be stored on this drive: the name isn't allowed.": "“%@” không thể lưu trên ổ này: tên không được phép.",
    "“%@” is too large for this drive's file system.": "“%@” quá lớn đối với hệ tệp của ổ này.",
    "…and %lld more": "…và %lld mục nữa",
    "A folder can't be copied into itself.": "Không thể sao chép một thư mục vào chính nó.",
    "That name can't be used.": "Không dùng được tên này.",
    "An item named “%@” already exists.": "Đã có mục tên “%@”.",
    "About %@ left": "Còn khoảng %@",
    "Read %@ · Write %@": "Đọc %1$@ · Ghi %2$@",
    "%@ of %@": "%1$@ trên %2$@",
    "File Transfer": "Sao chép tệp",
    "File Transfer is in beta. Keep a second copy of anything important.": "Sao chép tệp đang ở bản Beta. Hãy giữ thêm một bản sao của dữ liệu quan trọng.",
    "Copy": "Sao chép",
    "New Folder": "Thư mục mới",
    "Rename": "Đổi tên",
    "Delete": "Xoá",
    "Quick Look": "Xem nhanh",
    "Copy the selection to the other side": "Sao chép mục đã chọn sang bên kia",
    "Name": "Tên",
    "Size": "Kích thước",
    "Date Modified": "Ngày sửa",
    "Open": "Mở",
    "Copy to the Other Side": "Sao chép sang bên kia",
    "Move to Trash": "Chuyển vào Thùng rác",
    "Selected: %lld · %@": "Đã chọn: %lld · %@",
    "Items: %lld": "Mục: %lld",
    "Items: %lld · %@ free": "Mục: %lld · còn trống %@",
    "Can't open this folder": "Không mở được thư mục này",
    "This folder is empty": "Thư mục này trống",
    "Back": "Quay lại",
    "Forward": "Tiến tới",
    "Enclosing Folder": "Thư mục chứa",
    "Can't copy everything": "Không thể sao chép tất cả",
    "Copy the Rest": "Sao chép phần còn lại",
    "Create": "Tạo",
    "untitled folder": "thư mục chưa đặt tên",
    "Delete permanently?": "Xoá vĩnh viễn?",
    "These items can't be moved to the Trash. They will be deleted permanently.": "Không thể chuyển các mục này vào Thùng rác. Chúng sẽ bị xoá vĩnh viễn.",
    "Drag files between the two sides, or select files and press Copy.": "Kéo tệp giữa hai bên, hoặc chọn tệp rồi bấm Sao chép.",
    "Copying files: %lld of %lld": "Đang sao chép: %lld / %lld tệp",
    "Paused": "Đã tạm dừng",
    "Pause": "Tạm dừng",
    "Resume": "Tiếp tục",
    "Skip This File": "Bỏ qua tệp này",
    "All": "Tất cả",
    "Copying": "Đang chép",
    "Errors": "Lỗi",
    "Waiting": "Đang chờ",
    "Done": "Xong",
    "Failed": "Lỗi",
    "Skipped": "Đã bỏ qua",
    "Errors: %lld": "Lỗi: %lld",
    "Retry Failed": "Thử lại tệp lỗi",
    "Export Error List…": "Xuất danh sách lỗi…",
    "Clear": "Xoá danh sách",
    "Options": "Tuỳ chọn",
    "Verify after copy": "Xác minh sau khi sao chép",
    "Ask what to do on errors": "Hỏi khi gặp lỗi",
    "Prevent sleep while copying": "Chặn máy ngủ khi đang chép",
    "“%@” already exists": "“%@” đã tồn tại",
    "Already there": "Đang có sẵn",
    "Being copied": "Đang sao chép",
    "Apply to all": "Áp dụng cho tất cả",
    "Replace": "Thay thế",
    "Keep Both": "Giữ cả hai",
    "Skip": "Bỏ qua",
    "Replace If Newer": "Chỉ thay nếu mới hơn",
    "Couldn't copy “%@”": "Không sao chép được “%@”",
    "Retry": "Thử lại",
    "Stop": "Dừng",
    "Copying files…": "Đang sao chép tệp…",
    "Files are still being copied": "Các tệp vẫn đang được sao chép",
    "Quitting now cancels the copy and removes the unfinished files.": "Thoát bây giờ sẽ huỷ việc sao chép và xoá các tệp chưa xong.",
    "Keep Copying": "Tiếp tục sao chép",
}

with open(PATH, encoding="utf-8") as handle:
    catalog = json.load(handle)

added = 0
for key, value in NEW.items():
    if key in catalog["strings"]:
        continue
    catalog["strings"][key] = {"localizations": {"vi": {"stringUnit": {"state": "translated", "value": value}}}}
    added += 1

with open(PATH, "w", encoding="utf-8") as handle:
    json.dump(catalog, handle, indent=2, ensure_ascii=False, separators=(",", " : "))
    handle.write("\n")
print("added", added)
```

Run: `python3 /tmp/add-strings.py && git diff --stat App/Localizable.xcstrings`
Expected: `added` is a number below 95 (some keys such as Cancel, Settings or Finder already exist and are skipped), and the diff shows only added lines. If the diff shows reformatting of existing entries, restore with `git checkout App/Localizable.xcstrings` and instead paste the new entries by hand in the same JSON shape.

- [ ] **Step 4: Build, run all app tests, check Vietnamese**

Run: `xcodebuild -scheme NTFSForMac -only-testing:NTFSForMacTests CODE_SIGNING_ALLOWED=NO test 2>&1 | rg "Test run with|TEST SUCCEEDED|TEST FAILED|error:|✘"`
Expected: `TEST SUCCEEDED` with 120 tests.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "Show copy progress in the menu bar, confirm quitting mid-copy, and add Vietnamese strings." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

---

### Task 13: Real-drive check, changelog and version

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `Config/Base.xcconfig`

- [ ] **Step 1: Build the signed app and install it**

```bash
scripts/build-local.sh
killall "NTFS for Mac" 2>/dev/null || true
rm -rf "/Applications/NTFS for Mac.app"
ditto "build/DerivedData/Build/Products/Release/NTFS for Mac.app" "/Applications/NTFS for Mac.app"
open "/Applications/NTFS for Mac.app"
```

- [ ] **Step 2: Check each of these by hand with the Lexar E6 (`NTFS_CUONG_2`) and the Mac, and write what you saw**

1. The sidebar shows **File Transfer** with an orange BETA capsule above the drive list. Opening it shows the title with the same capsule, and the notice banner. Dismissing the banner keeps it dismissed after quitting and reopening.
2. Left pane on Home, right pane on `NTFS_CUONG_2`. Drag one file from left to right: the progress panel fills, shows the percentage, read and write speeds and the time left, and a notification appears at the end ("Copy complete").
3. Select three files and one folder with files inside, press **Copy**: all arrive on the right with the same dates; the folder keeps its structure.
4. Copy a file of 1 GB or more: press **Pause**, the numbers stop; press **Resume**, it carries on; the copy matches (`shasum -a 256` of both).
5. Copy the same file again: the conflict sheet appears; check **Keep Both**, **Skip** and **Replace If Newer** once each, and **Apply to all** with several files.
6. Turn on **Verify after copy** and copy a few files: it takes longer and finishes without errors.
7. Pull the USB cable of the destination during a large copy: the panel says a drive was disconnected and offers **Resume**; reconnect, press **Resume**, the file restarts and finishes. No `.ntfs-part` files remain on the drive.
8. Copy a file named `a:b.txt` to an exFAT volume (`SSD-PUBLIC`): the "Can't copy everything" alert names it and **Copy the Rest** copies the others. The same file to the NTFS volume copies without the alert.
9. Make a read error (copy from a damaged file, or use the Flaky test as a reference): the file shows red with the reason, the run continues, **Retry Failed** and **Export Error List…** work.
10. Right-click: Open, Rename, New Folder, Move to Trash, Show in Finder all work in both panes. Deleting on the NTFS volume asks before deleting for good. Space opens Quick Look.
11. Make the window narrow: the sidebar hides and the two panes stack once below about 900 pt wide.
12. Quit during a copy: the "Files are still being copied" dialog appears; **Quit** removes the unfinished file.
13. Switch the system language to Vietnamese and look at the page, the panel and the prompts for untranslated English.

Anything that fails here is a bug to fix in the task that owns it, with a test first where the logic is in the package.

- [ ] **Step 3: Version and changelog**

In `Config/Base.xcconfig` change `MARKETING_VERSION = 2.1.0` to `MARKETING_VERSION = 2.2.0` and `CURRENT_PROJECT_VERSION = 7` to `CURRENT_PROJECT_VERSION = 8`.

In `CHANGELOG.md`, directly under `## [Unreleased]`, add:

```markdown
## [2.2.0] Lotus - 2026-11-04

### Added

- **File Transfer (Beta).** A new page in the main window with two file browsers side by side. Drag files from one side to the other, press **Copy**, or use ⌘C and ⌘V. A panel underneath shows the progress, the read and write speed, the time left, every file and its state, and the files that failed with the reason. Copying can be paused, resumed, cancelled and retried for the failed files, and a notification says when it is done.
- Name conflicts offer Replace, Keep Both, Skip or Replace If Newer, with an option to apply the choice to every file.
- **Verify after copy** compares a checksum of each file with its original. **Ask what to do on errors** turns a failed file into a Skip, Retry or Stop prompt.
- Files are written under a temporary name and renamed when complete, so an unplugged drive never keeps a half-written file. A drive that runs out of space or is removed pauses the copy until you resume it.
- New Folder, Rename, Delete (to the Trash) and Quick Look in either pane. The copy keeps the Mac awake, shows its progress on the Dock icon and in the menu bar menu, and asks before quitting while it runs.
```

And at the bottom of the file, replace `[Unreleased]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.1.0...HEAD` with
```markdown
[Unreleased]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/dovancuongadhp/ntfs-for-mac/compare/v2.1.0...v2.2.0
```

- [ ] **Step 4: Run every test one last time**

```bash
swift test --package-path Core --filter NTFSTransferTests
xcodebuild -scheme NTFSForMac -only-testing:NTFSForMacTests CODE_SIGNING_ALLOWED=NO test 2>&1 | rg "Test run with|TEST SUCCEEDED|TEST FAILED|error:|✘"
```
Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md Config/Base.xcconfig
git commit -m "Prepare 2.2.0: changelog and version for File Transfer (Beta)." -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
```

Releasing (merge to `main`, tag `v2.2.0`, DMG, GitHub release notes in `docs/releases/v2.2.0.md`) is a separate step done only when asked, the same way 2.1.0 was.

---

## Self-Review

**Spec coverage**

| Spec requirement | Task |
| --- | --- |
| Sidebar row with BETA badge; title badge; first-run notice | 3 (badge), 9, 10 |
| Two panes, any drive or Mac folder, stack below 900 pt | 7, 10 |
| Copy by drag, Copy button, ⌘C/⌘V, Finder drops | 8 (session), 10 |
| Engine: chunked, temp file + rename, symlinks, dates, no `._` files | 2, 5 |
| Read and write speed, progress, time left, per-file status | 4 (meter), 5, 6, 11 |
| Pause/Resume, Skip, Cancel, Retry failed | 4, 5, 6, 11 |
| Conflicts with Apply to all | 5, 11 |
| Ask-on-error prompt | 5, 11 |
| Verify after copy | 5 |
| Preflight: space, names, FAT32 | 3, 8, 11 |
| Error classes: unreadable, no space, drive removed, permission, invalid name, checksum | 1, 5, 6 |
| New Folder, Rename, Delete/Trash, Quick Look, Show in Finder | 7, 8, 9, 10 |
| Notification at the end, Dock progress, menu bar line, prevent sleep, quit confirmation | 8, 12 |
| Vietnamese strings | 12 |
| Tests: engine, fake failures, queue, preflight, real-drive check | 1–7, 13 |

Gaps accepted and written into Global Constraints: name validation only for exFAT/FAT32; dates via `FileManager`; the file restarts after a drive removal. Dragging several rows relies on the drop handler picking up the whole selection (Task 10).

**Placeholder scan:** no TBD or "similar to Task N". Task 2 deliberately defers part of `Fixtures.swift` to Task 5 and says exactly what goes where.

**Type consistency:** `TransferFailure(.reason, detail:)`, `TransferOutcome` fields (`stop`, `copied`, `failed`, `skipped`, `bytes`, `remaining`), `TransferQueue.Phase.stopped(TransferStop)`, `ConflictRequest.info`, `TransferProgress.failedItems`/`summary()`, `TransferText.notice(for:stop:)`, and `TransferSession.start(_:)` are used with the same names in every task that touches them.

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
        // `.skipHiddenVolumes` also drops FSKit mounts (the NTFS driver), so filter by hand.
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        for url in fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard isListedVolume(path: url.standardizedFileURL.path, browsable: values?.volumeIsBrowsable) else { continue }
            let name = values?.volumeName ?? url.lastPathComponent
            let symbol = values?.volumeIsInternal == false ? "externaldrive" : "internaldrive"
            places.append(FileLocation(name: name, url: url, symbol: symbol))
        }
        return places
    }

    /// The startup disk, or a drive mounted directly in /Volumes that is not flagged hidden.
    public static func isListedVolume(path: String, browsable: Bool?) -> Bool {
        if path == "/" { return true }
        guard browsable != false else { return false }
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path == "/Volumes" && !url.lastPathComponent.isEmpty
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

    /// The result of a trash operation.
    public struct TrashResult: Sendable {
        /// Items on a volume that has no Trash – these may be offered for permanent deletion.
        public var stuck: [URL]
        /// The first non-Trash error (permission denied, I/O error, …); nothing was deleted for these.
        public var error: Error?
    }

    /// Moves items to the Trash.
    ///
    /// An item is "stuck" only when the file system has no Trash support
    /// (`NSFeatureUnsupportedError`). Any other error (permission denied, etc.) is
    /// collected as `error` and the item is left untouched – it must NOT be offered for
    /// permanent deletion.
    public static func trash(_ urls: [URL]) -> TrashResult {
        var stuck: [URL] = []
        var firstError: Error?
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch let err as NSError {
                if err.domain == NSCocoaErrorDomain, err.code == NSFeatureUnsupportedError {
                    stuck.append(url)
                } else {
                    if firstError == nil { firstError = err }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        return TrashResult(stuck: stuck, error: firstError)
    }

    /// Permanently deletes items after a preflight that refuses when any item's parent is
    /// not writable – preventing the inside-out partial-delete data-loss pattern.
    public static func deletePermanently(_ urls: [URL]) throws {
        for url in urls {
            guard FileManager.default.isDeletableFile(atPath: url.path) else {
                throw CocoaError(.fileWriteNoPermission,
                                 userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        for url in urls { try FileManager.default.removeItem(at: url) }
    }
}

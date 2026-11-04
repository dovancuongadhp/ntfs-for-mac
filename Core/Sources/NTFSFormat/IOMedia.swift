import Foundation
import IOKit

/// IOKit properties of IOMedia objects that DiskArbitration doesn't report.
/// `path` is DiskArbitration's `DAMediaPath`.
public enum IOMedia {
    public static func number(_ path: String, _ key: String) -> UInt64? {
        withEntry(path) { (property($0, key) as? NSNumber)?.uint64Value }.flatMap { $0 }
    }

    public static func strings(_ path: String, _ key: String) -> [String] {
        withEntry(path) { property($0, key) as? [String] }.flatMap { $0 } ?? []
    }

    /// The BSD name of the nearest IOMedia above this one, e.g. the partition
    /// that stores an APFS container.
    public static func parentBSDName(_ path: String) -> String? {
        withEntry(path) { parentBSDName(of: $0) }.flatMap { $0 }
    }

    /// Same as `parentBSDName(_:)`, found by BSD name instead of a registry path.
    /// DiskArbitration's path does not resolve when a node name contains a space,
    /// which leaves an APFS container looking like a second copy of the drive.
    public static func parentBSDName(bsdName: String) -> String? {
        guard let entry = media(named: bsdName) else { return nil }
        defer { IOObjectRelease(entry) }
        return parentBSDName(of: entry)
    }

    /// BSD names of the nearest IOMedia objects above this one on every path
    /// through the registry, e.g. each physical store of an APFS container.
    /// A media object without a BSD name is listed as an empty string, so it
    /// still counts.
    public static func ancestorBSDNames(_ path: String) -> [String] {
        withEntry(path) { ancestorBSDNames(of: $0) } ?? []
    }

    /// Same as `ancestorBSDNames(_:)`, found by BSD name when the registry path does not resolve.
    public static func ancestorBSDNames(bsdName: String) -> [String] {
        guard let entry = media(named: bsdName) else { return [] }
        defer { IOObjectRelease(entry) }
        return ancestorBSDNames(of: entry)
    }

    private static func parentBSDName(of entry: io_registry_entry_t) -> String? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        var parent: io_registry_entry_t = 0
        while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOMedia") != 0 {
                return property(current, "BSD Name") as? String
            }
        }
        return nil
    }

    private static func ancestorBSDNames(of entry: io_registry_entry_t) -> [String] {
        var names: [String] = []
        var seen: Set<UInt64> = []
        var pending: [io_registry_entry_t] = []
        func addParents(of entry: io_registry_entry_t) {
            var iterator: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(iterator) }
            while case let parent = IOIteratorNext(iterator), parent != IO_OBJECT_NULL {
                pending.append(parent)
            }
        }
        addParents(of: entry)
        while let current = pending.popLast() {
            defer { IOObjectRelease(current) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(current, &id) == KERN_SUCCESS, seen.insert(id).inserted else {
                continue
            }
            if IOObjectConformsTo(current, "IOMedia") != 0 {
                names.append(property(current, "BSD Name") as? String ?? "")
            } else {
                addParents(of: current)
            }
        }
        return names.sorted()
    }

    private static func media(named bsdName: String) -> io_registry_entry_t? {
        guard let matching = IOServiceMatching("IOMedia") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let object = IOIteratorNext(iterator), object != IO_OBJECT_NULL {
            if (property(object, "BSD Name") as? String) == bsdName {
                return object
            }
            IOObjectRelease(object)
        }
        return nil
    }

    private static func withEntry<T>(_ path: String, _ body: (io_registry_entry_t) -> T) -> T? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        return body(entry)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

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
        withEntry(path) { entry -> String? in
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
        }.flatMap { $0 }
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

import Foundation
import Observation

/// Per-drive settings, keyed by `NTFSDisk.preferenceKey`.
@MainActor
@Observable
final class VolumePreferences {
    @ObservationIgnored private let defaults: UserDefaults
    private var readOnlyKeys: Set<String>

    private static let storageKey = "ReadOnlyVolumes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        readOnlyKeys = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    /// Drives are writable unless the user turned writing off for them.
    func isWriteEnabled(_ key: String) -> Bool {
        !readOnlyKeys.contains(key)
    }

    func setWriteEnabled(_ enabled: Bool, for key: String) {
        if enabled {
            readOnlyKeys.remove(key)
        } else {
            readOnlyKeys.insert(key)
        }
        defaults.set(readOnlyKeys.sorted(), forKey: Self.storageKey)
    }
}

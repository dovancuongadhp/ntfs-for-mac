import Foundation

/// The copy log on disk, so it is still there after the app quits until the person clears it.
public enum TransferLog {
    /// Nil when there is no log yet, or it can't be read.
    public static func load(from url: URL) -> TransferQueue.Log? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TransferQueue.Log.self, from: data)
    }

    public static func save(_ log: TransferQueue.Log, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(log).write(to: url, options: .atomic)
    }
}

import AppKit
import Foundation

/// `2.0.1` and `v2.0.2`, compared as three numbers.
struct AppVersion: Comparable, Equatable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    var text: String { "\(major).\(minor).\(patch)" }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `nil` when the text is not a version, such as a pre-release tag.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        // A pre-release tag such as 2.0.2-beta is not an offered update.
        if text.contains("-") { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static var current: AppVersion {
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return AppVersion(text) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The newest GitHub release that ships `NTFS-for-Mac.dmg`.
struct GitHubRelease: Equatable, Sendable {
    static let latestURL = URL(string: "https://api.github.com/repos/dovancuongadhp/ntfs-for-mac/releases/latest")!
    static let assetName = "NTFS-for-Mac.dmg"

    var version: AppVersion
    var downloadURL: URL

    static func latest(from data: Data) throws -> GitHubRelease {
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(decoded.tag_name),
              let asset = decoded.assets.first(where: { $0.name == assetName }),
              let url = URL(string: asset.browser_download_url),
              url.scheme == "https",
              url.host() == "github.com",
              url.path.hasPrefix("/dovancuongadhp/ntfs-for-mac/releases/download/"),
              url.lastPathComponent == assetName
        else { throw UpdateError.untrustedDownload }
        return GitHubRelease(version: version, downloadURL: url)
    }

    private struct Payload: Decodable {
        var tag_name: String
        var assets: [Asset]
    }

    private struct Asset: Decodable {
        var name: String
        var browser_download_url: String
    }
}

enum UpdateError: Error, Equatable {
    case unavailable
    case untrustedDownload
    case installFailed
}

/// Looks for a newer release and, when asked, replaces this app with it.
@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppVersion)
        case downloading
        case failed
        case checkFailed
    }

    private(set) var phase: Phase = .idle
    private var offered: GitHubRelease?

    /// `reportFailure` is for the button the user pressed. A quiet check
    /// leaves the phase idle when GitHub cannot be reached.
    func check(reportFailure: Bool = false) async {
        switch phase {
        case .checking, .downloading, .available: return
        case .idle, .upToDate, .failed, .checkFailed: break
        }
        phase = .checking
        do {
            var request = URLRequest(url: GitHubRelease.latestURL)
            request.timeoutInterval = 20
            request.setValue("NTFS-for-Mac", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.unavailable }
            let release = try GitHubRelease.latest(from: data)
            if release.version > AppVersion.current {
                offered = release
                phase = .available(release.version)
            } else {
                offered = nil
                phase = .upToDate
            }
        } catch {
            appLog.error("Update check failed: \(String(describing: error), privacy: .public)")
            phase = reportFailure ? .checkFailed : .idle
        }
    }

    func install() async {
        guard case .available = phase, let offered else { return }
        phase = .downloading
        do {
            let staged = try await Task.detached { try await AppInstaller.stage(offered) }.value
            try AppInstaller.scheduleSwap(of: staged, over: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            appLog.error("Update failed: \(String(describing: error), privacy: .public)")
            phase = .failed
        }
    }
}

enum AppInstaller {
    /// Downloads the disk image, checks the app inside is the offered version, and copies it aside.
    static func stage(_ release: GitHubRelease) async throws -> URL {
        let (downloaded, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.unavailable
        }
        let dmg = FileManager.default.temporaryDirectory.appending(path: "NTFS-for-Mac-update.dmg")
        if FileManager.default.fileExists(atPath: dmg.path) {
            try FileManager.default.removeItem(at: dmg)
        }
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        let mount = FileManager.default.temporaryDirectory.appending(path: "ntfs-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        } catch {
            try? FileManager.default.removeItem(at: mount)
            throw error
        }
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path])
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: dmg)
        }
        let source = mount.appending(path: "NTFS for Mac.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.untrustedDownload }
        let staged = FileManager.default.temporaryDirectory.appending(path: "NTFS for Mac update.app")
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.removeItem(at: staged)
        }
        try run("/usr/bin/ditto", [source.path, staged.path])
        guard version(of: staged) == release.version else { throw UpdateError.untrustedDownload }
        return staged
    }

    /// After this process quits, replaces `destination` with `staged` and opens it.
    static func scheduleSwap(of staged: URL, over destination: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appending(path: "ntfs-for-mac-update.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        pid=\(ProcessInfo.processInfo.processIdentifier)
        src=\(shellQuote(staged.path))
        dest=\(shellQuote(destination.path))
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2
        done
        tmp="$dest.update"
        backup="$dest.previous"
        rm -rf "$tmp"
        /usr/bin/ditto "$src" "$tmp"
        rm -rf "$backup"
        mv "$dest" "$backup"
        if mv "$tmp" "$dest"; then
          rm -rf "$backup"
        else
          mv "$backup" "$dest" || true
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$dest" || true
        /usr/bin/open "$dest"
        rm -rf "$src"
        rm -f \(shellQuote(scriptURL.path))
        """
        try Data(script.utf8).write(to: scriptURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &"]
        try process.run()
    }

    private static func version(of app: URL) -> AppVersion? {
        let info = app.appending(path: "Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: info),
              let text = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return AppVersion(text)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ launch: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.installFailed }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

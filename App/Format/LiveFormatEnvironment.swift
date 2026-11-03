import Foundation
import NTFSFormat

/// Formats real drives: DiskArbitration, `diskutil`, and `ntfs-format` through
/// the macOS administrator prompt.
@MainActor
struct LiveFormatEnvironment: FormatEnvironment {
    let inventory: DiskInventory
    let mounter: MountController

    func freshInfo(_ bsdName: String) -> DiskInfo? {
        inventory.freshInfo(bsdName)
    }

    func childNames(ofWhole bsdName: String) -> [String] {
        inventory.childNames(ofWhole: bsdName)
    }

    func apfsPhysicalStores(ofStore store: String) -> [String]? {
        inventory.apfsPhysicalStores(ofStore: store)
    }

    func unmount(_ bsdName: String, whole: Bool) async throws {
        try await mounter.unmount(bsdName: bsdName, whole: whole)
    }

    func runDiskutil(_ arguments: [String]) async throws {
        let result = try await CommandLineTool.run("/usr/sbin/diskutil", arguments)
        appLog.notice("diskutil \(arguments.joined(separator: " "), privacy: .public): \(result.status) \(result.output, privacy: .public)")
        guard result.status == 0 else { throw FormatError.failed(result.lastLine) }
    }

    func runNTFSFormat(_ request: FormatRequest) async throws {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ntfs-format").path
        let command = ([helper] + request.arguments).map(MountController.shellQuoted).joined(separator: " ") + " 2>&1"
        let prompt = String(localized: "NTFS for Mac needs administrator rights to format “\(request.label)” as NTFS.")
        let script = "do shell script \(MountController.appleScriptQuoted(command))"
            + " with prompt \(MountController.appleScriptQuoted(prompt)) with administrator privileges"
        // osascript, not NSAppleScript: a full format can take hours and must not block the main thread.
        let result = try await CommandLineTool.run("/usr/bin/osascript", ["-e", script])
        appLog.notice("ntfs-format \(request.device, privacy: .public): \(result.status) \(result.output, privacy: .public)")
        guard result.status == 0 else { throw PrivilegedOutput.error(fromOsascript: result.output) }
    }

    func pause(_ duration: Duration) async {
        // Detached, so cancelling the format task can't turn the wait into a busy loop.
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
    }
}

struct CommandResult: Sendable {
    var status: Int32
    var output: String

    var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

enum CommandLineTool {
    static func run(_ path: String, _ arguments: [String]) async throws -> CommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Reads why `do shell script … with administrator privileges` failed. The
/// error number at the end is the script's exit status, or -128 for Cancel.
enum PrivilegedOutput {
    static func error(fromOsascript output: String) -> FormatError {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: /\((-?[0-9]+)\)$/), let code = Int32(match.1) else {
            return .failed(trimmed)
        }
        if code == -128 {
            return .cancelled
        }
        if let error = FormatToolError(rawValue: code) {
            return .tool(error)
        }
        return .failed(trimmed)
    }
}

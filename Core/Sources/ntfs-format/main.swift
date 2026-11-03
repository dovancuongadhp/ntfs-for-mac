import Foundation
import NTFSFormat

// Formats one external partition as NTFS. Runs as root through the app's
// administrator prompt, so it re-checks everything the app checked and
// verifies the partition table before writing anything.

func formatPartition() throws {
    let request = try FormatRequest.parse(Array(CommandLine.arguments.dropFirst()))
    guard let wholeDevice = request.wholeDevice else { throw FormatToolError.notAPartition }
    // Block mounts before inspecting, so nothing can be mounted after the check.
    try MountBlocker.blocking(wholeDevice) {
        let facts = try DeviceInspector.facts(for: request.device)
        try FormatGuard.check(request, facts: facts)
        try format(request, facts: facts)
    }
}

func format(_ request: FormatRequest, facts: DeviceFacts) throws {
    var table: (original: [UInt8], typeField: Int)?
    if facts.scheme == FormatGuard.mbrScheme, let index = facts.partitionID {
        let block = try RawDisk.readFirstBlock(of: facts.wholeDevice, blockSize: Int(facts.blockSize))
        let typeField = try MBR.typeFieldOffset(
            in: block, index: index, start: request.offset, size: request.size, blockSize: facts.blockSize)
        if block[typeField] != MBR.ntfsType {
            // Refuse a busy disk now, while nothing has been erased.
            try RawDisk.checkWritable(facts.wholeDevice)
            // Opening the whole disk read-write makes macOS re-probe its partitions.
            try DeviceInspector.waitForPartition(request.device, size: request.size)
            table = (block, typeField)
        }
    }

    try runMkntfs(MkntfsCommand.arguments(request, sectorSize: facts.blockSize))

    if let table {
        var block = table.original
        block[table.typeField] = MBR.ntfsType
        try RawDisk.replaceFirstBlock(of: facts.wholeDevice, expected: table.original, with: block)
    }
}

func runMkntfs(_ arguments: [String]) throws {
    let directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let process = Process()
    process.executableURL = directory.appendingPathComponent("ntfs-mkfs")
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("ntfs-format: cannot run ntfs-mkfs: \(error.localizedDescription)\n".utf8))
        throw FormatToolError.mkntfsFailed
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FormatToolError.mkntfsFailed }
}

do {
    try formatPartition()
} catch let error as FormatToolError {
    FileHandle.standardError.write(Data("ntfs-format: \(error)\n".utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data("ntfs-format: \(error.localizedDescription)\n".utf8))
    exit(FormatToolError.ioError.exitCode)
}

import Foundation
import NTFSFormat

// Formats one external partition as NTFS. Runs as root through the app's
// administrator prompt, so it re-checks everything the app checked and
// verifies the partition table before writing anything.

func formatPartition() throws {
    let request = try FormatRequest.parse(Array(CommandLine.arguments.dropFirst()))
    let facts = try DeviceInspector.facts(for: request.device)
    try FormatGuard.check(request, facts: facts)

    var table: (disk: RawDisk, original: [UInt8], typeField: Int)?
    if facts.scheme == FormatGuard.mbrScheme, let index = facts.partitionID {
        let disk = try RawDisk(wholeDevice: facts.wholeDevice, blockSize: Int(facts.blockSize))
        let block = try disk.readFirstBlock()
        let typeField = try MBR.typeFieldOffset(
            in: block, index: index, start: request.offset, size: request.size, blockSize: facts.blockSize)
        if block[typeField] != MBR.ntfsType {
            table = (disk, block, typeField)
        }
    }

    try runMkntfs(MkntfsCommand.arguments(request, sectorSize: facts.blockSize))

    if let table {
        var block = try table.disk.readFirstBlock()
        guard block == table.original else { throw FormatToolError.badPartitionTable }
        block[table.typeField] = MBR.ntfsType
        try table.disk.writeFirstBlock(block)
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

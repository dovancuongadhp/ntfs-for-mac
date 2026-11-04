import Darwin
import Foundation
import NTFSFormat

// Formats one external partition as NTFS. macOS refuses a direct open of a
// removable disk, so the partition is opened through authopen (which asks for
// an administrator password) and handed to mkntfs. Everything the app checked
// is checked again before that descriptor is used.

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
    let partition = "/dev/" + request.device
    let whole = "/dev/" + facts.wholeDevice
    let session = try DiskSession(partition: partition, whole: whole)
    defer { session.close() }

    var table: (original: [UInt8], typeField: Int)?
    if facts.scheme == FormatGuard.mbrScheme, let index = facts.partitionID {
        let wholeFD = try session.open(whole)
        let block = try RawDisk.readFirstBlock(fd: wholeFD, blockSize: Int(facts.blockSize))
        close(wholeFD)
        let typeField = try MBR.typeFieldOffset(
            in: block, index: index, start: request.offset, size: request.size, blockSize: facts.blockSize)
        if block[typeField] != MBR.ntfsType {
            // Opening the whole disk read-write makes macOS re-probe its partitions.
            try DeviceInspector.waitForPartition(request.device, size: request.size)
            table = (block, typeField)
        }
    }

    let partitionFD = try session.open(partition)
    try runMkntfs(MkntfsCommand.arguments(request, sectorSize: facts.blockSize), diskPath: partition, fd: partitionFD)
    close(partitionFD)

    if let table {
        var block = table.original
        block[table.typeField] = MBR.ntfsType
        let wholeFD = try session.open(whole)
        defer { close(wholeFD) }
        try RawDisk.replaceFirstBlock(fd: wholeFD, expected: table.original, with: block)
    } else {
        // The file system is already written; a missed re-probe only delays DiskArbitration noticing it.
        do {
            let wholeFD = try session.open(whole)
            close(wholeFD)
        } catch {
            FileHandle.standardError.write(Data("ntfs-format: warning: could not re-probe \(whole) (\(error))\n".utf8))
        }
    }
}

func runMkntfs(_ arguments: [String], diskPath: String, fd: Int32) throws {
    let directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let executable = directory.appendingPathComponent("ntfs-mkfs").path
    do {
        try MkntfsLauncher.run(executable: executable, arguments: arguments, diskPath: diskPath, fd: fd)
    } catch {
        FileHandle.standardError.write(Data("ntfs-format: ntfs-mkfs failed: \(error)\n".utf8))
        throw error
    }
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

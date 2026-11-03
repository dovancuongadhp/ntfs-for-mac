/// The `mkntfs` command line for a request.
public enum MkntfsCommand {
    /// Runs on the block device without `-F`. mkntfs can't tell whether a
    /// partition is mounted on macOS, so `FormatGuard` checks that before it
    /// runs. Geometry and start sector go in the boot sector, where Windows
    /// expects them.
    public static func arguments(_ request: FormatRequest, sectorSize: UInt64) -> [String] {
        let startSector = request.offset / sectorSize
        var arguments = [
            "-s", String(sectorSize),
            "-p", String(startSector <= UInt64(UInt32.max) ? startSector : 0),
            "-H", "255", "-S", "63",
            "-L", request.label,
        ]
        if let clusterSize = request.clusterSize {
            arguments += ["-c", String(clusterSize)]
        }
        if request.quick {
            arguments.append("-Q")
        }
        arguments.append("/dev/" + request.device)
        return arguments
    }
}

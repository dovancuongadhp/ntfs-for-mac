/// What the app asks `ntfs-format` to do, and the command line that carries it.
public struct FormatRequest: Equatable, Sendable {
    /// BSD name of the partition, e.g. `disk6s2`.
    public var device: String
    /// Partition size and start on the disk, in bytes, as the app saw them.
    public var size: UInt64
    public var offset: UInt64
    public var label: String
    /// Bytes per cluster; `nil` lets mkntfs choose.
    public var clusterSize: Int?
    public var quick: Bool

    public init(device: String, size: UInt64, offset: UInt64, label: String, clusterSize: Int?, quick: Bool) {
        self.device = device
        self.size = size
        self.offset = offset
        self.label = label
        self.clusterSize = clusterSize
        self.quick = quick
    }

    /// BSD name of the disk holding the partition, e.g. `disk6`, or `nil` if
    /// `device` doesn't name a partition.
    public var wholeDevice: String? {
        device.wholeMatch(of: /(disk[0-9]+)s[0-9]+/).map { String($0.1) }
    }

    public var arguments: [String] {
        var arguments = ["--device", device, "--size", String(size), "--offset", String(offset), "--label", label]
        if let clusterSize {
            arguments += ["--cluster", String(clusterSize)]
        }
        if quick {
            arguments.append("--quick")
        }
        return arguments
    }

    public static func parse(_ arguments: [String]) throws -> FormatRequest {
        var values: [String: String] = [:]
        var quick = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--quick":
                quick = true
            case "--device", "--size", "--offset", "--label", "--cluster":
                guard values[argument] == nil, let value = iterator.next() else { throw FormatToolError.usage }
                values[argument] = value
            default:
                throw FormatToolError.usage
            }
        }
        guard let device = values["--device"],
              let size = values["--size"].flatMap(UInt64.init),
              let offset = values["--offset"].flatMap(UInt64.init),
              let label = values["--label"]
        else { throw FormatToolError.usage }
        var clusterSize: Int?
        if let text = values["--cluster"] {
            guard let value = Int(text) else { throw FormatToolError.usage }
            clusterSize = value
        }
        return FormatRequest(device: device, size: size, offset: offset, label: label, clusterSize: clusterSize, quick: quick)
    }
}

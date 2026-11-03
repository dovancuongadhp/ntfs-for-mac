import NTFSShared
import SwiftUI

struct PartitionDetailView: View {
    let model: AppModel
    let partition: Partition
    let disk: PhysicalDisk

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let mount = partition.mount, mount.totalBytes > 0 {
                    usage(mount)
                }
                InfoGrid(rows: rows)
                if let ntfs = partition.ntfsDisk {
                    NTFSOptionsView(model: model, disk: ntfs, isLocked: model.formatting.contains(disk.bsdName))
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            DriveIcon(systemImage: "externaldrive.fill", colors: partition.mount == nil ? [.gray, .secondary] : [.blue, .indigo])
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(partition.name).font(.title2.bold()).lineLimit(1)
                    Badge(text: partition.fileSystem.label)
                    Badge(text: status.text, tint: status.color)
                }
                Text([disk.name, partition.bsdName, disk.connection].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: (text: String, color: Color) {
        if let ntfs = partition.ntfsDisk {
            let state = model.state(of: ntfs)
            return (state.label, state.color)
        }
        guard let mount = partition.mount else { return (String(localized: "Not mounted"), .secondary) }
        return mount.isReadOnly ? (String(localized: "Read-only"), .orange) : (String(localized: "Read & write"), .blue)
    }

    private func usage(_ mount: NTFSDisk.Mount) -> some View {
        let used = mount.totalBytes - min(mount.freeBytes, mount.totalBytes)
        return VStack(alignment: .leading, spacing: 8) {
            SegmentedBar(segments: [
                .init(id: "used", fraction: Double(used) / Double(mount.totalBytes), color: .accentColor),
            ])
            HStack(spacing: 16) {
                LegendItem(color: .accentColor, text: String(localized: "Used \(used.formatted(.byteCount(style: .file)))"))
                LegendItem(color: .secondary.opacity(0.3), text: String(localized: "Free \(mount.freeBytes.formatted(.byteCount(style: .file)))"))
                Spacer()
                Text("Total \(mount.totalBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rows: [InfoRow] {
        [
            InfoRow(label: String(localized: "Mounted at"), value: partition.mount?.path.path ?? String(localized: "Not mounted")),
            InfoRow(label: String(localized: "Capacity"), value: (partition.mount?.totalBytes ?? partition.size).formatted(.byteCount(style: .file))),
            InfoRow(label: String(localized: "Device"), value: partition.bsdName),
            InfoRow(label: String(localized: "Driver"), value: driver),
            InfoRow(label: "UUID", value: partition.volumeUUID ?? "—"),
        ]
    }

    private var driver: String {
        guard let mount = partition.mount else { return "—" }
        switch mount.fileSystemType {
        case Identifiers.fileSystemTypeName: return "NTFS for Mac"
        case Identifiers.systemDriverTypeName: return String(localized: "macOS (read-only)")
        default: return "macOS"
        }
    }
}

/// "Allow writing" and read-only advice for an NTFS partition.
struct NTFSOptionsView: View {
    let model: AppModel
    let disk: NTFSDisk
    /// The drive is being formatted, so its settings can't change now.
    var isLocked = false

    private var isBusy: Bool { isLocked || model.busy.contains(disk.bsdName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if disk.isRecognized {
                Toggle(isOn: Binding(
                    get: { model.isWriteEnabled(disk) },
                    set: { model.setWriteEnabled($0, for: disk) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow writing")
                        Text("Turn off to always mount this drive read-only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(isBusy || !disk.isWritableMedia)
            }
            if case .readOnly(let reason?) = model.state(of: disk), reason != .requested {
                Text(reason.advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == .uncleanJournal, model.isWriteEnabled(disk), !isBusy {
                    Button("Allow Writing Anyway…") { AllowWritingConfirmation.run(model: model, disk: disk) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

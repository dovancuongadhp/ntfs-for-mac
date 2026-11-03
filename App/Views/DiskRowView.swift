import SwiftUI

struct DiskRowView: View {
    let model: AppModel
    let disk: NTFSDisk

    private var state: DiskState { model.state(of: disk) }
    private var isBusy: Bool { model.busy.contains(disk.bsdName) || model.isBeingFormatted(disk.bsdName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(state.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    actions
                }
            }

            if let mount = disk.mount, mount.totalBytes > 0 {
                let used = mount.totalBytes - min(mount.freeBytes, mount.totalBytes)
                ProgressView(value: Double(used), total: Double(mount.totalBytes))
                Text("\(used.formatted(.byteCount(style: .file))) of \(mount.totalBytes.formatted(.byteCount(style: .file))) used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if disk.isRecognized {
                Toggle("Allow writing", isOn: Binding(
                    get: { model.isWriteEnabled(disk) },
                    set: { model.setWriteEnabled($0, for: disk) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isBusy || !disk.isWritableMedia)
            }

            if state == .readOnly(.uncleanJournal), model.isWriteEnabled(disk), !isBusy {
                Button("Allow Writing Anyway…") { AllowWritingConfirmation.run(model: model, disk: disk) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            if disk.mount != nil {
                Button {
                    model.reveal(disk)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            } else if disk.isRecognized {
                Button("Mount") { model.mount(disk) }
            }
            if !isOnProtectedDisk {
                Button {
                    model.eject(disk)
                } label: {
                    Image(systemName: "eject.fill")
                }
                .help("Eject")
                .accessibilityLabel("Eject")
            }
        }
        .buttonStyle(.borderless)
    }

    private var isOnProtectedDisk: Bool {
        model.inventory.partition(named: disk.bsdName).map { model.isProtected($0.disk) } ?? false
    }
}

extension DiskState {
    var color: Color {
        switch self {
        case .readWrite: .green
        case .readOnly, .systemReadOnly: .orange
        case .notMounted: .secondary
        case .unrecognized: .red
        }
    }
}

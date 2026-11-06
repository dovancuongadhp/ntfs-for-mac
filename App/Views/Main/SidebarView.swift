import SwiftUI

enum SidebarSelection: Hashable {
    case disk(String)
    case partition(String)
    case settings
    case transfer
    case welcome
}

struct SidebarView: View {
    let model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        let disks = model.inventory.sidebarDisks
        List(selection: $selection) {
            Section {
                Label("Welcome", systemImage: "house")
                    .tag(SidebarSelection.welcome)
                HStack {
                    Label("File Transfer", systemImage: "arrow.left.arrow.right")
                    Spacer()
                    switch model.transfer.sidebarStatus {
                    case .needsAnswer:
                        // Visible whichever page is shown, even when the app is the active one.
                        Image(systemName: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Needs your answer")
                            .accessibilityLabel("Needs your answer")
                    case .working:
                        ProgressView().controlSize(.small)
                    case .none:
                        EmptyView()
                    }
                }
                .tag(SidebarSelection.transfer)
            }
            if disks.isEmpty {
                Section("Drives") {
                    Text("Connect a drive and it will appear here.")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            section("External", disks.filter { !$0.isInternal })
            section("Internal", disks.filter(\.isInternal))
            Section("NTFS for Mac") {
                HStack {
                    Label("Settings", systemImage: "gearshape")
                    Spacer()
                    if model.extensionStatus.isEnabled == false {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .help("The file system extension is turned off")
                    }
                }
                .tag(SidebarSelection.settings)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ disks: [PhysicalDisk]) -> some View {
        if !disks.isEmpty {
            Section(title) {
                ForEach(disks) { disk in
                    DiskSidebarRow(model: model, disk: disk)
                        .tag(SidebarSelection.disk(disk.bsdName))
                    ForEach(disk.sidebarPartitions) { partition in
                        PartitionSidebarRow(model: model, partition: partition)
                            .padding(.leading, 14)
                            .tag(SidebarSelection.partition(partition.bsdName))
                    }
                }
            }
        }
    }
}

private struct DiskSidebarRow: View {
    let model: AppModel
    let disk: PhysicalDisk

    var body: some View {
        HStack {
            Label(disk.name, systemImage: disk.kind.symbol ?? (disk.isInternal ? "internaldrive" : "externaldrive"))
                .lineLimit(1)
            Spacer()
            if model.busy.contains(disk.bsdName) || model.formatting.contains(disk.bsdName) {
                ProgressView().controlSize(.small)
            } else if model.isProtected(disk) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help("Protected")
                    .accessibilityLabel("Protected")
            } else if model.canEject(disk) {
                Button {
                    model.eject(disk)
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .help("Eject")
                .accessibilityLabel("Eject")
            }
        }
    }
}

private struct PartitionSidebarRow: View {
    let model: AppModel
    let partition: Partition

    var body: some View {
        HStack {
            Label(partition.name, systemImage: partition.mount == nil ? "externaldrive" : "externaldrive.fill")
                .lineLimit(1)
                .opacity(partition.mount == nil ? 0.6 : 1)
            Spacer()
            if model.busy.contains(partition.bsdName) || model.isBeingFormatted(partition.bsdName) {
                ProgressView().controlSize(.small)
            }
            Text(partition.fileSystem.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

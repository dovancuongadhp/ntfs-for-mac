import SwiftUI

struct MainWindowView: View {
    let model: AppModel
    @State private var selection: SidebarSelection?
    @State private var formatTarget: FormatTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.dismissError() }
                }
                detail
            }
        }
        .toolbar { toolbar }
        .sheet(item: $formatTarget) { target in
            FormatSheet(model: model, target: target)
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear(perform: selectDefault)
        .onChange(of: model.inventory.tree) { _, _ in keepSelectionValid() }
        .task {
            while !Task.isCancelled {
                model.inventory.refreshUsage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let found = selectedPartition {
            PartitionDetailView(model: model, partition: found.partition, disk: found.disk)
        } else if case .disk = selection, let disk = selectedDisk {
            DiskDetailView(model: model, disk: disk)
        } else {
            ContentUnavailableView("Select a drive or partition", systemImage: "externaldrive")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let found = selectedPartition {
                if found.partition.mount != nil {
                    Button("Unmount", systemImage: "eject.circle") { model.unmount(found.partition) }
                        .disabled(!model.canUnmount(found.partition, on: found.disk))
                } else {
                    Button("Mount", systemImage: "arrow.up.circle") { model.mount(found.partition) }
                        .disabled(!found.partition.isRecognized || model.isProtected(found.disk)
                                  || model.busy.contains(found.partition.bsdName)
                                  || model.formatting.contains(found.disk.bsdName))
                }
            }
            Button("Eject", systemImage: "eject") {
                if let disk = selectedDisk { model.eject(disk) }
            }
            .disabled(!(selectedDisk.map { model.canEject($0) } ?? false))
            Button("Show in Finder", systemImage: "folder") {
                if let partition = selectedPartition?.partition { model.reveal(partition) }
            }
            .disabled(selectedPartition?.partition.mount == nil)
            Button("Format…", systemImage: "eraser") { formatTarget = currentFormatTarget }
                .disabled(currentFormatTarget == nil || formatBlock != nil)
                .help(formatBlock?.message ?? String(localized: "Erase and format"))
        }
    }

    private var selectedPartition: (partition: Partition, disk: PhysicalDisk)? {
        guard case .partition(let name)? = selection else { return nil }
        return model.inventory.partition(named: name)
    }

    private var selectedDisk: PhysicalDisk? {
        switch selection {
        case .disk(let name)?: model.inventory.physicalDisk(named: name)
        case .partition(let name)?: model.inventory.partition(named: name)?.disk
        case nil: nil
        }
    }

    private var currentFormatTarget: FormatTarget? {
        switch selection {
        case .disk(let name)?: .disk(name)
        case .partition(let name)?: .partition(name)
        case nil: nil
        }
    }

    private var formatBlock: FormatBlock? {
        guard let target = currentFormatTarget, let disk = selectedDisk else { return nil }
        return FormatSafety.blockReason(for: target, on: disk, context: model.formatContext)
    }

    private func selectDefault() {
        guard selection == nil else { return }
        let disks = model.inventory.sidebarDisks
        let disk = disks.first { !$0.isInternal } ?? disks.first
        if let partition = disk?.sidebarPartitions.first {
            selection = .partition(partition.bsdName)
        } else if let disk {
            selection = .disk(disk.bsdName)
        }
    }

    private func keepSelectionValid() {
        let isValid = switch selection {
        case .partition(let name)?: model.inventory.partition(named: name) != nil
        case .disk(let name)?: model.inventory.physicalDisk(named: name) != nil
        case nil: false
        }
        if !isValid {
            selection = nil
            selectDefault()
        }
    }
}

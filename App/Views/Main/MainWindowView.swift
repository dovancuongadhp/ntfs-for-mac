import SwiftUI

struct MainWindowView: View {
    let model: AppModel
    @Bindable var navigation: MainNavigation
    @State private var formatTarget: FormatTarget?
    @State private var columns = NavigationSplitViewVisibility.all
    /// The sidebar was folded away by the window getting narrow, not by the user,
    /// so it comes back when the window is wide again.
    @State private var sidebarFoldedByWidth = false

    /// Below this the sidebar and the page can't both fit.
    private static let foldWidth: CGFloat = 700

    private var selection: SidebarSelection? {
        get { navigation.selection }
        nonmutating set { navigation.selection = newValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model, selection: $navigation.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .background { ToolbarLabelStyleFix() }
        .sheet(item: $formatTarget) { target in
            FormatSheet(model: model, target: target)
        }
        .frame(minWidth: 460, minHeight: 400)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if width < Self.foldWidth, columns != .detailOnly {
                sidebarFoldedByWidth = true
                columns = .detailOnly
            } else if width >= Self.foldWidth, sidebarFoldedByWidth {
                sidebarFoldedByWidth = false
                columns = .all
            }
        }
        .onAppear(perform: selectDefault)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.extensionStatus.refresh()
        }
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
        if selection == .settings {
            SettingsView(model: model)
        } else if let found = selectedPartition {
            PartitionDetailView(model: model, partition: found.partition, disk: found.disk)
        } else if case .disk = selection, let disk = selectedDisk {
            DiskDetailView(model: model, disk: disk)
        } else {
            ContentUnavailableView("Select a drive or partition", systemImage: "externaldrive")
        }
    }

    /// The same four buttons on every page, dimmed when they don't apply, so the
    /// toolbar keeps one height and one layout like Disk Utility's.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let found = selectedPartition, found.partition.mount != nil {
            actionItem("Unmount", systemImage: "externaldrive.badge.minus", disabled: !model.canUnmount(found.partition, on: found.disk)) {
                model.unmount(found.partition)
            }
        } else {
            actionItem("Mount", systemImage: "externaldrive.badge.plus", disabled: !canMount) {
                if let partition = selectedPartition?.partition { model.mount(partition) }
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Eject", systemImage: "eject", disabled: !(selectedDisk.map { model.canEject($0) } ?? false)) {
            if let disk = selectedDisk { model.eject(disk) }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem(
            "Finder", systemImage: "folder", help: String(localized: "Show in Finder"),
            disabled: selectedPartition?.partition.mount == nil
        ) {
            if let partition = selectedPartition?.partition { model.reveal(partition) }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem(
            "Format", systemImage: "eraser",
            help: formatBlock?.message ?? String(localized: "Erase and format"),
            disabled: currentFormatTarget == nil || formatBlock != nil
        ) { formatTarget = currentFormatTarget }
    }

    private var canMount: Bool {
        guard let found = selectedPartition else { return false }
        return found.partition.isRecognized
            && !(model.isProtected(found.disk) && found.partition.ntfsDisk == nil)
            && !model.busy.contains(found.partition.bsdName)
            && !model.formatting.contains(found.disk.bsdName)
    }

    private func actionItem(
        _ title: LocalizedStringKey, systemImage: String, help: String? = nil,
        disabled: Bool = false, action: @escaping () -> Void
    ) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            toolbarButton(title, systemImage: systemImage, help: help, disabled: disabled, action: action)
        }
    }

    @ViewBuilder
    private func toolbarButton(
        _ title: LocalizedStringKey, systemImage: String, help: String?,
        disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        if let help {
            Button(title, systemImage: systemImage, action: action)
                .disabled(disabled)
                .help(help)
        } else {
            Button(title, systemImage: systemImage, action: action)
                .disabled(disabled)
                .help(Text(title))
        }
    }

    private var currentFormatTarget: FormatTarget? {
        switch selection {
        case .disk(let name)?: .disk(name)
        case .partition(let name)?: .partition(name)
        case .settings?, nil: nil
        }
    }

    private var formatBlock: FormatBlock? {
        guard let target = currentFormatTarget, let disk = selectedDisk else { return nil }
        return FormatSafety.blockReason(for: target, on: disk, context: model.formatContext)
    }

    private var selectedPartition: (partition: Partition, disk: PhysicalDisk)? {
        guard case .partition(let name)? = selection else { return nil }
        return model.inventory.partition(named: name)
    }

    private var selectedDisk: PhysicalDisk? {
        switch selection {
        case .disk(let name)?: model.inventory.physicalDisk(named: name)
        case .partition(let name)?: model.inventory.partition(named: name)?.disk
        case .settings?, nil: nil
        }
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
        case .settings?: true
        case nil: false
        }
        if !isValid {
            selection = nil
            selectDefault()
        }
    }
}

/// Keeps the toolbar on icon-and-title, the same arrangement Disk Utility uses.
private struct ToolbarLabelStyleFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let toolbar = view.window?.toolbar, toolbar.displayMode != .iconAndLabel else { return }
            toolbar.displayMode = .iconAndLabel
        }
    }
}

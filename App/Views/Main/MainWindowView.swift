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
        if selection == .transfer {
            TransferPage(session: model.transfer)
        } else if selection == .settings {
            SettingsView(model: model)
        } else if let found = selectedPartition {
            PartitionDetailView(model: model, partition: found.partition, disk: found.disk)
        } else if case .disk = selection, let disk = selectedDisk {
            DiskDetailView(model: model, disk: disk)
        } else {
            WelcomeView(model: model) { selection = $0 }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selection == .transfer {
            transferToolbar
        } else {
            driveToolbar
        }
    }

    /// The file copy page has its own buttons, in the same style and height.
    @ToolbarContentBuilder
    private var transferToolbar: some ToolbarContent {
        actionItem("New Folder", systemImage: "folder.badge.plus") { model.transfer.beginNewFolder() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Rename", systemImage: "pencil", disabled: !model.transfer.canRename) { model.transfer.beginRename() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        actionItem("Delete", systemImage: "trash", disabled: !model.transfer.canDelete) { model.transfer.requestDelete() }
        // A ToolbarContentBuilder takes at most ten children, so the last buttons sit in a group.
        Group {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            actionItem("Quick Look", systemImage: "eye", disabled: !model.transfer.canPreview) { model.transfer.preview() }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            actionItem("Finder", systemImage: "folder", help: String(localized: "Show in Finder")) { model.transfer.revealInFinder() }
        }
    }

    /// The same four buttons on every drive page, dimmed when they don't apply, so the
    /// toolbar keeps one height and one layout like Disk Utility's.
    @ToolbarContentBuilder
    private var driveToolbar: some ToolbarContent {
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
        case .settings?, .transfer?, .welcome?, nil: nil
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
        case .settings?, .transfer?, .welcome?, nil: nil
        }
    }

    private func selectDefault() {
        if selection == nil { selection = .welcome }
    }

    private func keepSelectionValid() {
        let isValid = switch selection {
        case .partition(let name)?: model.inventory.partition(named: name) != nil
        case .disk(let name)?: model.inventory.physicalDisk(named: name) != nil
        case .settings?, .transfer?, .welcome?: true
        case nil: false
        }
        if !isValid {
            selection = nil
            selectDefault()
        }
    }
}

/// Where the window opens: whether the driver is on, the drives plugged in, and the way to the other pages.
private struct WelcomeView: View {
    let model: AppModel
    let open: (SidebarSelection) -> Void

    var body: some View {
        Form {
            PageBanners(model: model, showsExtensionWarning: false)
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NTFS for Mac").font(.title2.weight(.semibold))
                        Text("Read and write Windows drives right in Finder.").foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.versionString)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                driverStatus
            }

            Section("Drives") {
                let partitions = model.inventory.sidebarDisks.filter { !$0.isInternal }.flatMap(\.sidebarPartitions)
                if partitions.isEmpty {
                    Text("Connect a drive and it will appear here.").foregroundStyle(.secondary)
                }
                ForEach(partitions, id: \.bsdName) { partition in
                    shortcut(systemImage: partition.mount == nil ? "externaldrive" : "externaldrive.fill") {
                        Text(partition.name).lineLimit(1)
                        Spacer()
                        Text(partition.fileSystem.label).foregroundStyle(.secondary)
                        Text((partition.mount?.totalBytes ?? partition.size).formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } action: {
                        open(.partition(partition.bsdName))
                    }
                }
            }

            Section("Get started") {
                shortcut(systemImage: "arrow.left.arrow.right") {
                    page("File Transfer", "Copy files between drives in a two-sided browser.")
                } action: {
                    open(.transfer)
                }
                shortcut(systemImage: "gearshape") {
                    page("Settings", "The NTFS driver, language, updates and more.")
                } action: {
                    open(.settings)
                }
            }
        }
        .detailColumn()
        .onAppear { model.extensionStatus.refresh() }
    }

    @ViewBuilder private var driverStatus: some View {
        switch model.extensionStatus.isEnabled {
        case true?:
            Label("The NTFS driver is on. Plug in a Windows drive and use it like any other.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case false?:
            HStack {
                Label("The NTFS driver is off, so Windows drives are read-only.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Turn It On") { open(.settings) }
            }
        case nil:
            EmptyView()
        }
    }

    private func page(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A whole row that opens a page, with an arrow like a link in System Settings.
    private func shortcut(
        systemImage: String, @ViewBuilder label: () -> some View, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                label()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

import NTFSTransfer
import SwiftUI

/// One side of the page: where you are, what's there, and what's selected.
struct FilePaneView: View {
    @Bindable var session: TransferSession
    let pane: TransferPane
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name)]
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = session.model(for: pane)
        let isActive = session.activePane == pane
        VStack(spacing: 0) {
            header(model, isActive: isActive)
                .overlay(alignment: .top) {
                    if isActive { Color.accentColor.frame(height: 2) }
                }
            Divider()
            table(model: model)
            Divider()
            footer(model)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.drop(urls, onto: pane)
        } isTargeted: { isTargeted = $0 }
        .simultaneousGesture(TapGesture().onEnded { session.activePane = pane })
    }

    // MARK: Header

    private func header(_ model: FileBrowserModel, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back")
                    .accessibilityLabel("Back")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                    .accessibilityLabel("Forward")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!model.canGoUp)
                    .help("Enclosing Folder")
                    .accessibilityLabel("Enclosing Folder")
                locationMenu(model)
                Spacer(minLength: 0)
                Button {
                    session.activePane = pane
                    Task { await session.refresh(pane) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut(isActive ? KeyboardShortcut("r", modifiers: .command) : nil)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .buttonStyle(.borderless)
            Text(model.folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func locationMenu(_ model: FileBrowserModel) -> some View {
        let current = Locations.containing(model.folder, in: session.locations)
        return Menu {
            ForEach(session.locations) { location in
                Button { model.open(location.url) } label: {
                    Label(location.name, systemImage: location.symbol)
                }
            }
        } label: {
            Label(current?.name ?? model.folder.lastPathComponent, systemImage: current?.symbol ?? "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Table

    private func table(model: FileBrowserModel) -> some View {
        @Bindable var model = model
        return Table(of: FileEntry.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1)
                } icon: {
                    Image(systemName: entry.isFolder ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                }
            }
            TableColumn("Size", value: \.size) { entry in
                Text(entry.isFolder ? "—" : TransferText.size(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("Date Modified", value: \.modified) { entry in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140, max: 190)
        } rows: {
            ForEach(model.entries) { entry in
                TableRow(entry).draggable(entry.url)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            menu(for: urls)
        } primaryAction: { urls in
            open(urls, in: model)
        }
        .onChange(of: sortOrder) { _, comparators in
            model.sort = FileSort(comparators: comparators)
        }
        .onChange(of: model.selection) { _, selection in
            if !selection.isEmpty { session.activePane = pane }
        }
        .onCopyCommand {
            session.copyToPasteboard(from: pane)
            return session.copyProviders(for: pane)
        }
        .onPasteCommand(of: [.fileURL]) { _ in session.pasteFromPasteboard(into: pane) }
        .onDeleteCommand {
            session.activePane = pane
            session.requestDelete()
        }
        .onKeyPress(.space) {
            session.activePane = pane
            session.preview()
            return .handled
        }
        .overlay {
            if let message = model.errorMessage {
                ContentUnavailableView(
                    "Can't open this folder", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            } else if model.entries.isEmpty, !model.isLoading {
                Text("This folder is empty").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for urls: Set<URL>) -> some View {
        let protected = urls.contains { ProtectedFolders.isProtected($0) }
        if !urls.isEmpty {
            Button("Open") { open(Array(urls), in: session.model(for: pane)) }
            Button("Copy") {
                focus(urls)
                session.copyToPasteboard(from: pane)
            }
            Button("Copy to the Other Side") {
                focus(urls)
                session.copyActiveToOther()
            }
            Button("Quick Look") {
                focus(urls)
                session.preview()
            }
            if urls.count == 1 {
                Button("Rename") {
                    focus(urls)
                    session.beginRename()
                }
                .disabled(protected)
            }
            Button("Move to Trash") {
                focus(urls)
                session.requestDelete()
            }
            .disabled(protected)
            Button("Show in Finder") {
                focus(urls)
                session.revealInFinder()
            }
        }
        Button("Paste Here") {
            session.activePane = pane
            session.pasteFromPasteboard(into: pane)
        }
        .disabled(!session.pasteboardHasFiles)
        Button("New Folder") {
            session.activePane = pane
            session.beginNewFolder()
        }
    }

    /// Makes this side active and, if the menu was opened on rows outside the selection, selects them.
    private func focus(_ urls: Set<URL>) {
        session.activePane = pane
        let model = session.model(for: pane)
        if model.selection != urls { model.selection = urls }
    }

    private func open(_ urls: some Collection<URL>, in model: FileBrowserModel) {
        if urls.count == 1, let url = urls.first, let entry = model.entries.first(where: { $0.url == url }), entry.isFolder {
            model.open(url)
            return
        }
        for url in urls { NSWorkspace.shared.open(url) }
    }

    // MARK: Footer

    private func footer(_ model: FileBrowserModel) -> some View {
        HStack {
            if model.selection.isEmpty {
                if let free = model.freeBytes {
                    Text("Items: \(model.entries.count) · \(TransferText.size(free)) free")
                } else {
                    Text("Items: \(model.entries.count)")
                }
            } else {
                let size = model.selectedEntries.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }
                Text("Selected: \(model.selection.count) · \(TransferText.size(size))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private extension FileSort {
    /// Table column headers produce comparators; the model sorts with its own key and direction.
    init(comparators: [KeyPathComparator<FileEntry>]) {
        guard let first = comparators.first else {
            self.init(key: .name, ascending: true)
            return
        }
        let size: PartialKeyPath<FileEntry> = \FileEntry.size
        let modified: PartialKeyPath<FileEntry> = \FileEntry.modified
        let key: FileSortKey = first.keyPath == size ? .size : (first.keyPath == modified ? .modified : .name)
        self.init(key: key, ascending: first.order == .forward)
    }
}

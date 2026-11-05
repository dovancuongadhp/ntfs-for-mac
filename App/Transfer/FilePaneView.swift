import NTFSTransfer
import SwiftUI
import UniformTypeIdentifiers

/// One side of the page: where you are, what's there, and what's selected.
struct FilePaneView: View {
    @Bindable var session: TransferSession
    let pane: TransferPane
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name)]
    @State private var isTargeted = false
    @FocusState private var listFocused: Bool

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
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            receiveDrop(providers)
        }
    }

    // MARK: Header

    private func header(_ model: FileBrowserModel, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    session.activePane = pane
                    model.goBack()
                } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Back")
                    .accessibilityLabel("Back")
                Button {
                    session.activePane = pane
                    model.goForward()
                } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                    .accessibilityLabel("Forward")
                Button {
                    session.activePane = pane
                    model.goUp()
                } label: { Image(systemName: "arrow.up") }
                    .disabled(!model.canGoUp)
                    .help("Enclosing Folder")
                    .accessibilityLabel("Enclosing Folder")
                locationMenu(model)
                favoriteButton(model)
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
            AddressField(model: model, isActive: isActive) { session.activePane = pane }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func locationMenu(_ model: FileBrowserModel) -> some View {
        let current = Locations.containing(model.folder, in: session.locations)
        let favorites = session.favorites.urls
        return Menu {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites, id: \.path) { url in
                        placeButton(url, title: Self.favoriteTitle(url)) { model.open(url) }
                    }
                }
            }
            ForEach(session.locations) { location in
                placeButton(location.url, title: location.name) { model.open(location.url) }
            }
        } label: {
            Label {
                Text(current?.name ?? model.folder.lastPathComponent)
            } icon: {
                Image(nsImage: FileIcons.icon(for: current?.url ?? model.folder))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The star next to the place menu. Filled means this folder is pinned.
    private func favoriteButton(_ model: FileBrowserModel) -> some View {
        let pinned = session.favorites.contains(model.folder)
        return Button {
            session.activePane = pane
            session.toggleFavorite(model.folder)
        } label: {
            Image(systemName: pinned ? "star.fill" : "star")
                .foregroundStyle(pinned ? Color.yellow : Color.secondary)
        }
        .help(pinned ? Text("Remove from Favorites") : Text("Add to Favorites"))
        .accessibilityLabel(pinned ? Text("Remove from Favorites") : Text("Add to Favorites"))
    }

    private func placeButton(_ url: URL, title: String, open: @escaping () -> Void) -> some View {
        Button {
            session.activePane = pane
            open()
        } label: {
            Label { Text(title) } icon: { Image(nsImage: FileIcons.icon(for: url)) }
                .labelStyle(.titleAndIcon)
        }
    }

    private static func favoriteTitle(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    // MARK: Table

    private func table(model: FileBrowserModel) -> some View {
        @Bindable var model = model
        let up = model.parentURL.map {
            FileEntry(url: $0, name: "..", isFolder: true, size: 0, modified: .distantPast, isHidden: false)
        }
        let rows = (up.map { [$0] } ?? []) + model.entries
        return Table(of: FileEntry.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1)
                } icon: {
                    if entry == up {
                        Image(systemName: "arrow.turn.left.up").foregroundStyle(.secondary)
                    } else {
                        Image(nsImage: FileIcons.icon(for: entry.url))
                    }
                }
            }
            TableColumn("Size", value: \.size) { entry in
                Text(entry == up ? "" : entry.isFolder ? "—" : TransferText.size(entry.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("Date Modified", value: \.modified) { entry in
                Text(entry == up ? "" : entry.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140, max: 190)
        } rows: {
            ForEach(rows) { entry in
                TableRow(entry).itemProvider { entry == up ? nil : NSItemProvider(object: entry.url as NSURL) }
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
            // Same value again still refreshes both panes, so only switch sides when the click landed elsewhere.
            if !selection.isEmpty, session.activePane != pane { session.activePane = pane }
        }
        .onCopyCommand {
            // Providers handed back here are added to the clipboard as copies in SwiftUI's cache folder,
            // which a paste would then copy a second time.
            session.copyToPasteboard(from: pane)
            return []
        }
        .onPasteCommand(of: [.fileURL]) { _ in session.pasteFromPasteboard(into: pane) }
        .onDeleteCommand {
            session.activePane = pane
            session.requestDelete()
        }
        .focused($listFocused)
        .onChange(of: listFocused) { _, focused in
            if focused {
                session.focusedList = pane
                if session.activePane != pane { session.activePane = pane }
            } else if session.focusedList == pane {
                session.focusedList = nil
            }
        }
        .onKeyPress(.return) {
            guard model.selection.count == 1 else { return .ignored }
            open(model.selection, in: model)
            return .handled
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
    private func menu(for clicked: Set<URL>) -> some View {
        let parent = session.model(for: pane).parentURL
        let urls = clicked.filter { $0 != parent }
        let protected = urls.contains { ProtectedFolders.isProtected($0) }
        if !urls.isEmpty {
            Button("Open") { open(Array(urls), in: session.model(for: pane)) }
            if urls.count == 1, let url = urls.first,
               session.model(for: pane).entries.contains(where: { $0.url == url && $0.isFolder }) {
                if session.favorites.contains(url) {
                    Button("Remove from Favorites") { session.toggleFavorite(url) }
                } else {
                    Button("Add to Favorites") { session.toggleFavorite(url) }
                }
            }
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
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(protected)
            Button("Delete Immediately…") {
                focus(urls)
                session.requestPermanentDelete()
            }
            .keyboardShortcut(.delete, modifiers: [.option, .command])
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

    /// Reads the file addresses themselves: decoding `URL` as a transferable copies every dropped item into
    /// SwiftUI's cache folder first, and the copy would be what gets copied.
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            session.drop(urls, onto: pane)
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private func open(_ urls: some Collection<URL>, in model: FileBrowserModel) {
        if urls.count == 1, let url = urls.first, url == model.parentURL {
            model.goUp()
            return
        }
        if urls.count == 1, let url = urls.first, let entry = model.entries.first(where: { $0.url == url }), entry.isFolder {
            model.open(url)
            return
        }
        for url in urls where url != model.parentURL { NSWorkspace.shared.open(url) }
    }

    // MARK: Footer

    private func footer(_ model: FileBrowserModel) -> some View {
        HStack {
            if model.actionableSelection.isEmpty {
                if let free = model.freeBytes {
                    Text("Items: \(model.entries.count) · \(TransferText.size(free)) free")
                } else {
                    Text("Items: \(model.entries.count)")
                }
            } else {
                let size = model.selectedEntries.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }
                Text("Selected: \(model.actionableSelection.count) · \(TransferText.size(size))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { session.activePane = pane }
    }
}

/// The pane's path. Clicking it, or ⌘L on the active side, turns it into a field that lists the matching
/// sub-folders as you type: Tab completes the highlighted one (the first until ↑ ↓ pick another) so typing
/// can go on inside it, Return opens the picked one or the typed path, Esc puts the path back.
private struct AddressField: View {
    let model: FileBrowserModel
    let isActive: Bool
    let activate: () -> Void
    @State private var editing = false
    @State private var text = ""
    @State private var invalid = false
    @State private var suggestions = PathSuggestions()
    @State private var keyMonitor: Any?
    @State private var lastSuggestionClick: (path: String, time: Date)?
    @FocusState private var focused: Bool

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static let rowHeight: CGFloat = 20

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Go to folder", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .foregroundStyle(invalid ? Color.red : Color.primary)
                    .focused($focused)
                    .help("Tab completes the highlighted folder, ↑ ↓ pick another, Return opens it")
                    .onSubmit(go)
                    .onExitCommand { editing = false }
                    .onChange(of: text) { invalid = false }
                    .onChange(of: focused) { _, now in if !now { editing = false } }
                    .task(id: text) {
                        let (typed, home) = (text, home)
                        let folders = await Task.detached(priority: .userInitiated) {
                            PathCompletion.suggestions(for: typed, home: home)
                        }.value
                        if !Task.isCancelled { suggestions = PathSuggestions(folders) }
                    }
                if !suggestions.folders.isEmpty { suggestionList }
            }
            .onAppear {
                focused = true
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let (code, flags) = (event.keyCode, event.modifierFlags)
                    let handled = MainActor.assumeIsolated { handleKey(code, flags) }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
        } else {
            Button(action: begin) {
                Text(model.folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(isActive ? KeyboardShortcut("l", modifiers: .command) : nil)
            .help("Click, or press ⌘L, to type a folder's path")
        }
    }

    private func begin() {
        activate()
        text = model.folder.path
        invalid = false
        editing = true
    }

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.folders.enumerated()), id: \.offset) { index, folder in
                        suggestionRow(folder, highlighted: index == suggestions.highlighted)
                            .id(index)
                    }
                }
            }
            .frame(height: min(CGFloat(suggestions.folders.count), 7) * Self.rowHeight)
            .background(.background, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            .onChange(of: suggestions.highlighted) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
    }

    private func suggestionRow(_ folder: URL, highlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: folder))
            Text(folder.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { clickSuggestion(folder) }
    }

    /// The first click completes at once. Waiting to see whether a second click is coming is what made a
    /// single click feel late, so a second click within the system double-click gap opens the folder instead.
    private func clickSuggestion(_ folder: URL) {
        let now = Date()
        if let last = lastSuggestionClick, last.path == folder.path,
           now.timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
            lastSuggestionClick = nil
            open(folder)
        } else {
            lastSuggestionClick = (folder.path, now)
            complete(with: folder.path + "/")
        }
    }

    /// Tab, ↑ ↓ and Return while this field is being typed in; anything else goes on to the field.
    private func handleKey(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard focused, flags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch code {
        case 48:
            if let completion = suggestions.completion {
                complete(with: completion)
            } else {
                NSSound.beep()
            }
            return true
        case 125:
            suggestions.moveDown()
            return true
        case 126:
            suggestions.moveUp()
            return true
        case 36, 76:
            guard let picked = suggestions.picked else { return false }
            open(picked)
            return true
        default:
            return false
        }
    }

    private func complete(with path: String) {
        text = path
        focused = true
    }

    private func go() {
        guard let folder = PathCompletion.folder(for: text, home: home) else {
            invalid = true
            NSSound.beep()
            return
        }
        open(folder)
    }

    private func open(_ folder: URL) {
        editing = false
        model.open(folder)
    }
}

/// Finder's icon for a file, folder or drive, at list size. Kept per path: rows are redrawn often, and asking
/// the system each time adds up in big folders.
@MainActor
private enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let icon = cache.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: key)
        return icon
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

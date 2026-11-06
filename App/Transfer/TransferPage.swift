import AppKit
import NTFSTransfer
import QuickLook
import SwiftUI

struct TransferPage: View {
    @Bindable var session: TransferSession
    @AppStorage("TransferProgressCollapsed") private var progressCollapsed = false
    /// Below this width the two sides stack instead of sitting side by side.
    private nonisolated static let stackWidth: CGFloat = 900
    /// The progress panel's bar alone.
    private nonisolated static let collapsedBarHeight: CGFloat = 38
    @Environment(\.undoManager) private var undoManager
    @State private var stacked = false
    @State private var deleteKeyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                panes.frame(minHeight: 240)
                TransferProgressPanel(session: session, collapsed: $progressCollapsed)
                    .frame(
                        minHeight: progressCollapsed ? Self.collapsedBarHeight : 120,
                        idealHeight: progressCollapsed ? Self.collapsedBarHeight : 240,
                        maxHeight: progressCollapsed ? Self.collapsedBarHeight : .infinity)
            }
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.stackWidth }) { stacked = $0 }
        .onAppear {
            session.pageVisible = true
            session.undoManager = undoManager
            if deleteKeyMonitor == nil { deleteKeyMonitor = Self.watchDeleteKeys(session) }
        }
        .onDisappear {
            session.pageVisible = false
            if let deleteKeyMonitor { NSEvent.removeMonitor(deleteKeyMonitor) }
            deleteKeyMonitor = nil
        }
        .task {
            await session.left.reload()
            await session.right.reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            session.volumesChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            session.volumesChanged()
        }
        .quickLookPreview($session.previewURL)
        .sheet(item: Binding(get: { session.queue.conflict }, set: { _ in })) { request in
            // Answers this request only, and starts fresh (own "Apply to all") for the next one.
            ConflictSheet(request: request) { session.queue.answer($0, for: request) }
                .id(request.id)
        }
        .sheet(item: Binding(get: { session.folderClash }, set: { _ in })) { clash in
            FolderClashSheet(clash: clash) { session.answerFolderClash($0, applyToAll: $1) }
                .id(clash.id)
        }
        .sheet(item: Binding(get: { session.queue.errorPrompt }, set: { _ in })) { request in
            ErrorSheet(request: request) { session.queue.answerError($0, for: request) }
                .id(request.id)
        }
        .alert(
            namePromptTitle,
            isPresented: Binding(get: { session.namePrompt != nil }, set: { if !$0 { session.namePrompt = nil } })
        ) {
            TextField("Name", text: $session.promptText)
            Button("Cancel", role: .cancel) {}
            Button(namePromptButton) { session.commitNamePrompt() }
        }
        .alert(
            session.pendingTransferTitle,
            isPresented: Binding(get: { session.pendingTransfer != nil }, set: { if !$0 { session.pendingTransfer = nil } }),
            presenting: session.pendingTransfer
        ) { pending in
            switch pending.choice {
            case .copyAnyway: Button("Copy Anyway") { session.start(pending.restOfJobs, removeAfter: pending.removeAfter) }
            case .copyTheRest: Button("Copy the Rest") { session.start(pending.restOfJobs, removeAfter: pending.removeAfter) }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(TransferText.problems(pending.problems))
        }
        .alert(
            "Delete permanently?",
            isPresented: Binding(get: { session.deleteRequest != nil }, set: { if !$0 { session.deleteRequest = nil } }),
            presenting: session.deleteRequest
        ) { _ in
            Button("Delete", role: .destructive) { session.confirmDelete() }
            // Return must NOT confirm a destructive action – put the default action on Cancel.
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { request in
            Text(TransferText.deleteMessage(for: request))
        }
        .alert(
            "File Transfer",
            isPresented: Binding(get: { session.alertMessage != nil }, set: { if !$0 { session.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(session.alertMessage ?? "")
        }
    }

    /// AppKit hands ⌘⌫ to the table before SwiftUI's key handlers see it, so the keys are caught here first.
    /// Only while a file list has focus: in a text field the same keys edit the text.
    private static func watchDeleteKeys(_ session: TransferSession) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let key = TransferSession.deleteKey(keyCode: event.keyCode, flags: event.modifierFlags) else { return event }
            let listHasFocus = MainActor.assumeIsolated { event.window?.firstResponder is NSTableView }
            let handled = listHasFocus && MainActor.assumeIsolated {
                guard let pane = session.focusedList else { return false }
                session.activePane = pane
                switch key {
                case .trash: session.requestDelete()
                case .immediately: session.requestPermanentDelete()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private var namePromptTitle: LocalizedStringKey {
        if case .rename? = session.namePrompt?.kind { "Rename" } else { "New Folder" }
    }

    private var namePromptButton: LocalizedStringKey {
        if case .rename? = session.namePrompt?.kind { "Rename" } else { "Create" }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("File Transfer").font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var panes: some View {
        if stacked {
            VSplitView {
                FilePaneView(session: session, pane: .left).frame(minHeight: 140)
                FilePaneView(session: session, pane: .right).frame(minHeight: 140)
            }
        } else {
            HSplitView {
                FilePaneView(session: session, pane: .left).frame(minWidth: 280)
                FilePaneView(session: session, pane: .right).frame(minWidth: 280)
            }
        }
    }
}

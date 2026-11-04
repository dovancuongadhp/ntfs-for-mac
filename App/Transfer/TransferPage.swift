import AppKit
import NTFSTransfer
import QuickLook
import SwiftUI

struct TransferPage: View {
    @Bindable var session: TransferSession
    @AppStorage("TransferBetaNoticeDismissed") private var noticeDismissed = false
    /// Below this width the two sides stack instead of sitting side by side.
    private nonisolated static let stackWidth: CGFloat = 900
    @State private var stacked = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !noticeDismissed { betaNotice }
            Divider()
            VSplitView {
                panes.frame(minHeight: 240)
                // Collapsed until a copy starts; `phase` changes once per copy, unlike the progress inside it.
                TransferProgressPanel(session: session)
                    .frame(
                        minHeight: session.queue.phase == .idle ? 44 : 120,
                        idealHeight: session.queue.phase == .idle ? 44 : 240)
            }
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.stackWidth }) { stacked = $0 }
        .onAppear { session.pageVisible = true }
        .onDisappear { session.pageVisible = false }
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
            case .copyAnyway: Button("Copy Anyway") { session.start(pending.restOfJobs) }
            case .copyTheRest: Button("Copy the Rest") { session.start(pending.restOfJobs) }
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
        } message: { urls in
            Text(TransferText.deleteMessage(for: urls))
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

    private var namePromptTitle: LocalizedStringKey {
        if case .rename? = session.namePrompt?.kind { "Rename" } else { "New Folder" }
    }

    private var namePromptButton: LocalizedStringKey {
        if case .rename? = session.namePrompt?.kind { "Rename" } else { "Create" }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("File Transfer").font(.title3.weight(.semibold))
            BetaBadge()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var betaNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text("File Transfer is in beta. Keep a second copy of anything important.")
                .font(.callout)
            Spacer()
            Button {
                noticeDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
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

import AppKit
import NTFSTransfer
import QuickLook
import SwiftUI

struct TransferPage: View {
    @Bindable var session: TransferSession
    @AppStorage("TransferBetaNoticeDismissed") private var noticeDismissed = false
    /// Below this width the two sides stack instead of sitting side by side.
    private static let stackWidth: CGFloat = 900
    @State private var stacked = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !noticeDismissed { betaNotice }
            Divider()
            panes
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.stackWidth }) { stacked = $0 }
        .task {
            await session.left.reload()
            await session.right.reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            session.refreshLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            session.refreshLocations()
        }
        .quickLookPreview($session.previewURL)
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

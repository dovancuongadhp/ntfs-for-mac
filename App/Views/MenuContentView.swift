import SwiftUI

struct MenuContentView: View {
    let model: AppModel
    let windows: WindowPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NTFS Drives")
                .font(.headline)

            if model.extensionStatus.isEnabled == false {
                ExtensionDisabledBanner(model: model)
            }

            if model.inventory.disks.isEmpty {
                Text("Connect a Windows (NTFS) drive and it will appear here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.inventory.disks) { disk in
                    DiskRowView(model: model, disk: disk)
                    if disk.id != model.inventory.disks.last?.id {
                        Divider()
                    }
                }
            }

            switch model.transfer.menuStatus {
            case .waiting:
                Button {
                    windows.showMain()
                } label: {
                    transferLine("Waiting for you", symbol: "exclamationmark.bubble.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            case .none, .copying, .paused:
                EmptyView()
            }

            if let error = model.lastError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        model.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
            }

            switch model.transfer.menuStatus {
            case .copying:
                transferLine("Copying files…", symbol: "arrow.left.arrow.right", showsProgress: true)
                    .foregroundStyle(.secondary)
            case .paused:
                transferLine("Paused", symbol: "pause.circle", showsProgress: true)
                    .foregroundStyle(.secondary)
            case .none, .waiting:
                EmptyView()
            }

            Divider()

            Button {
                windows.showMain()
            } label: {
                Label("Open NTFS for Mac…", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)

            if case .available(let version) = model.updates.phase {
                Button("Update to \(version.text)") { Task { await model.updates.install() } }
                    .disabled(model.isFormatting)
                    .buttonStyle(.borderless)
            } else if case .downloading = model.updates.phase {
                Text("Updating NTFS for Mac…")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Settings…") { windows.showSettings() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.extensionStatus.refresh() }
        .task {
            while !Task.isCancelled {
                model.inventory.refreshUsage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    /// One line about the copy. The symbol only decorates; the line reads as a single phrase to VoiceOver.
    private func transferLine(_ title: LocalizedStringKey, symbol: String, showsProgress: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(title)
            if showsProgress {
                Text(model.transfer.queue.progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

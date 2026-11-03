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

            Divider()

            Button {
                windows.showMain()
            } label: {
                Label("Open NTFS for Mac…", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)

            HStack {
                Button("Settings…") { windows.showSettings() }
                Button("Setup Guide") { windows.showWelcome() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.extensionStatus.refresh()
            model.inventory.refreshUsage()
        }
    }
}

private struct ExtensionDisabledBanner: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The file system extension is turned off", systemImage: "exclamationmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Drives stay read-only until you turn on NTFS for Mac in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { model.extensionStatus.openSystemSettings() }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

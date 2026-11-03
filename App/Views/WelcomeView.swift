import SwiftUI

struct WelcomeView: View {
    let model: AppModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to NTFS for Mac")
                        .font(.title2.weight(.semibold))
                    Text("Read and write Windows drives right in Finder.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Turn on the file system extension") {
                    Text("Open System Settings → General → Login Items & Extensions → File System Extensions, then switch on NTFS for Mac.")
                    HStack {
                        Button("Open System Settings") { model.extensionStatus.openSystemSettings() }
                        extensionBadge
                    }
                }
                Step(number: 2, title: "Connect your drive") {
                    Text("NTFS drives are mounted for reading and writing automatically and show up in Finder like any other drive.")
                }
                Step(number: 3, title: "Eject before unplugging") {
                    Text("Use Eject in Finder or in the menu bar so all changes are written to the drive.")
                }
            }

            Toggle("Open NTFS for Mac at login", isOn: Binding(
                get: { model.launchAtLogin.isEnabled },
                set: { model.launchAtLogin.setEnabled($0) }
            ))

            HStack {
                Text("To uninstall, quit the app and move it to the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder private var extensionBadge: some View {
        switch model.extensionStatus.isEnabled {
        case true?:
            Label("Turned on", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case false?:
            Label("Not turned on yet", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

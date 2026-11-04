import NTFSShared
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NTFS for Mac").font(.title3.weight(.semibold))
                        Text("Read and write Windows drives right in Finder.").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Status") { extensionBadge }
                if model.extensionStatus.isEnabled != true {
                    Text("Open System Settings → General → Login Items & Extensions → File System Extensions, then switch on NTFS for Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { model.extensionStatus.openSystemSettings() }
                }
            } header: {
                Text("File system extension")
            } footer: {
                Text("Use Eject in Finder or in the menu bar so all changes are written to the drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open NTFS for Mac at login", isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.setEnabled($0) }
                ))
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .onChange(of: language) { _, newValue in
                    newValue.apply()
                    languageChanged = true
                }
                if languageChanged {
                    Text("The new language is used the next time NTFS for Mac opens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                updateStatus
                LabeledContent("Author", value: "Đỗ Văn Cường")
                LabeledContent("Source code") {
                    Link("github.com/dovancuongadhp/ntfs-for-mac",
                         destination: URL(string: "https://github.com/dovancuongadhp/ntfs-for-mac")!)
                }
                LabeledContent("Found a bug?") {
                    Link("Report an issue",
                         destination: URL(string: "https://github.com/dovancuongadhp/ntfs-for-mac/issues/new")!)
                }
                Text("Free and open source under the GNU General Public License v2 or later. NTFS support is provided by ntfs-3g.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("To uninstall, quit the app and move it to the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .onAppear {
            model.extensionStatus.refresh()
            Task { await model.updates.check() }
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch model.updates.phase {
        case .available(let version):
            Button("Update to \(version.text)") { Task { await model.updates.install() } }
                .disabled(model.isFormatting)
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating NTFS for Mac…")
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .upToDate:
            updateRow("NTFS for Mac is up to date.", systemImage: "checkmark.circle.fill", tint: .green)
        case .checkFailed:
            updateRow("Couldn't check for updates.", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .failed:
            updateRow("The update could not be installed.", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .idle:
            HStack {
                Spacer()
                checkButton
            }
        }
    }

    private func updateRow(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(title)
            Spacer(minLength: 12)
            checkButton
        }
    }

    private var checkButton: some View {
        Button("Check for Updates…") { Task { await model.updates.check(reportFailure: true) } }
            .disabled(model.isFormatting)
    }

    @ViewBuilder private var extensionBadge: some View {
        switch model.extensionStatus.isEnabled {
        case true?:
            Label("Turned on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case false?:
            Label("Not turned on yet", systemImage: "circle.dashed").foregroundStyle(.orange)
        case nil where model.extensionStatus.hasChecked:
            Text("Not detected yet")
        case nil:
            ProgressView().controlSize(.small)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case vietnamese = "vi"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Same as system")
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    static var current: AppLanguage {
        guard let preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages"),
              UserDefaults.standard.persistentDomain(forName: Identifiers.appBundleID)?["AppleLanguages"] != nil,
              let first = preferred.first
        else { return .system }
        return first.hasPrefix("vi") ? .vietnamese : .english
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

private extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard let codename = infoDictionary?["NTFSCodename"] as? String, !codename.isEmpty else { return version }
        return "\(version) \(codename)"
    }
}

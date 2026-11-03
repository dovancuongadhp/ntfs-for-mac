import NTFSShared
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        Form {
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

            Section("File system extension") {
                LabeledContent("Status") {
                    switch model.extensionStatus.isEnabled {
                    case true?: Text("Turned on")
                    case false?: Text("Turned off")
                    case nil where model.extensionStatus.hasChecked: Text("Not detected yet")
                    case nil: ProgressView().controlSize(.small)
                    }
                }
                Button("Open System Settings") { model.extensionStatus.openSystemSettings() }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Text("Free and open source under the GNU General Public License v2 or later. NTFS support is provided by ntfs-3g.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

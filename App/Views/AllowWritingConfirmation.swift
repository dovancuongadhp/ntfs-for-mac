import AppKit

@MainActor
enum AllowWritingConfirmation {
    static func run(model: AppModel, disk: NTFSDisk) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Allow writing to “\(disk.name)”?")
        alert.informativeText = String(localized: "This drive wasn't ejected safely, or Windows didn't shut down cleanly. To write to it, NTFS for Mac clears the NTFS journal, and changes Windows hadn't finished saving may be lost.\n\nIf the drive belongs to a Windows PC that is hibernating or uses Fast Startup, shut that PC down fully instead.")
        alert.addButton(withTitle: String(localized: "Allow Writing"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.allowWritingAnyway(disk)
        }
    }
}

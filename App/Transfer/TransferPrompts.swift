import NTFSTransfer
import SwiftUI

/// Asks what to do when a file with the same name is already there.
struct ConflictSheet: View {
    let request: ConflictRequest
    let answer: (ConflictDecision) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("“\(request.info.name)” already exists")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Already there", request.info.existing)
                row("Being copied", request.info.source)
            }
            Toggle("Apply to all", isOn: $applyToAll)
            HStack {
                Button("Skip") { choose(.skip) }
                Button("Replace If Newer") { choose(.replaceIfNewer) }
                Spacer()
                Button("Keep Both") { choose(.keepBoth) }
                Button("Replace") { choose(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private func row(_ title: LocalizedStringKey, _ attributes: FileAttributes) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text("\(TransferText.size(attributes.size)) · \(attributes.modified.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private func choose(_ choice: ConflictChoice) {
        answer(ConflictDecision(choice: choice, applyToAll: applyToAll))
    }
}

/// Asks what to do after a file failed, when "Ask what to do on errors" is on.
struct ErrorSheet: View {
    let request: ErrorRequest
    let answer: (ErrorDecision) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Couldn't copy “\(request.info.name)”")
                .font(.headline)
            Text(TransferText.failure(request.info.failure.reason))
                .foregroundStyle(.secondary)
            Toggle("Apply to all", isOn: $applyToAll)
            HStack {
                Button("Stop") { choose(.stop) }
                Spacer()
                Button("Skip") { choose(.skip) }
                Button("Retry") { choose(.retry) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private func choose(_ choice: ErrorChoice) {
        answer(ErrorDecision(choice: choice, applyToAll: applyToAll))
    }
}

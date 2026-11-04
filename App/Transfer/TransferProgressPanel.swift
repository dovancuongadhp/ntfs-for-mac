import NTFSTransfer
import SwiftUI

/// Under the two sides: how far along the copy is, how fast, which files are done, and which failed.
struct TransferProgressPanel: View {
    @Bindable var session: TransferSession
    @State private var filter = Filter.all
    @AppStorage(TransferSession.verifyKey) private var verify = false
    @AppStorage(TransferSession.askOnErrorKey) private var askOnError = false
    @AppStorage(TransferSession.preventSleepKey) private var preventSleep = true

    enum Filter: Hashable {
        case all, copying, errors
    }

    private var queue: TransferQueue { session.queue }
    private var progress: TransferProgress { queue.progress }

    var body: some View {
        VStack(spacing: 0) {
            if progress.items.isEmpty {
                empty
            } else {
                summaryBlock
                Divider()
                list
                Divider()
                footer
            }
        }
        .background(.background)
    }

    private var empty: some View {
        HStack {
            Text("Drag files between the two sides, or select files and press Copy.")
                .foregroundStyle(.secondary)
            Spacer()
            optionsMenu
        }
        .padding(12)
    }

    // MARK: Summary

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusText).font(.headline)
                Spacer()
                optionsMenu
            }
            ProgressView(value: progress.fraction)
            HStack(spacing: 12) {
                Text("\(TransferText.size(progress.processedBytes)) of \(TransferText.size(progress.totalBytes))")
                if let seconds = progress.secondsRemaining, queue.phase == .running {
                    Text("About \(TransferText.duration(seconds)) left")
                }
                if progress.readRate > 0 || progress.writeRate > 0, queue.isBusy {
                    Text("Read \(TransferText.rate(progress.readRate)) · Write \(TransferText.rate(progress.writeRate))")
                }
                Spacer()
                controls
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var statusText: String {
        switch queue.phase {
        case .idle, .running:
            String(localized: "Copying files: \(progress.doneCount) of \(progress.fileCount)")
        case .paused:
            String(localized: "Paused")
        case .stopped(let stop):
            summaryTitle(stop)
        case .finished:
            summaryTitle(.finished)
        }
    }

    private func summaryTitle(_ stop: TransferStop) -> String {
        TransferText.notice(for: queue.summary ?? progress.summary(), stop: stop).title
    }

    @ViewBuilder
    private var controls: some View {
        switch queue.phase {
        case .running:
            Button("Pause") { queue.pause() }
            Button("Skip This File") { queue.skipCurrent() }
            Button("Cancel") { queue.cancel() }
        case .paused:
            Button("Resume") { queue.resume() }
            Button("Cancel") { queue.cancel() }
        case .stopped:
            Button("Resume") { queue.resume() }
            Button("Cancel") { queue.cancel() }
        case .idle, .finished:
            EmptyView()
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Verify after copy", isOn: $verify)
            Toggle("Ask what to do on errors", isOn: $askOnError)
            Toggle("Prevent sleep while copying", isOn: $preventSleep)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: List

    private var visibleItems: [TransferItem] {
        progress.items.filter { item in
            guard !item.job.isDirectory else { return false }
            switch filter {
            case .all: return true
            case .copying: return item.state == .copying || item.state == .waiting
            case .errors: return item.failure != nil
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                Text("All").tag(Filter.all)
                Text("Copying").tag(Filter.copying)
                Text("Errors").tag(Filter.errors)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.vertical, 6)
            List(visibleItems) { item in
                TransferRow(item: item)
            }
            .listStyle(.plain)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            let failed = progress.failedItems.count
            if failed > 0 {
                Label("Errors: \(failed)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Spacer()
            if failed > 0, !queue.isBusy {
                Button("Retry Failed") { queue.retryFailed() }
            }
            if failed > 0 {
                Button("Export Error List…") { session.exportFailures() }
            }
            if queue.phase == .finished {
                Button("Clear") { queue.clear() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.job.name).lineLimit(1)
                if let failure = item.failure {
                    Text(TransferText.failure(failure.reason))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Text(TransferText.size(item.job.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            statusView.frame(width: 90, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .copying: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.state {
        case .waiting: Text("Waiting").foregroundStyle(.secondary)
        case .copying:
            if item.job.size > 0 {
                Text(Double(item.bytesDone) / Double(item.job.size), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            } else {
                Text("Copying")
            }
        case .done: Text("Done").foregroundStyle(.secondary)
        case .failed: Text("Failed").foregroundStyle(.red)
        case .skipped: Text("Skipped").foregroundStyle(.secondary)
        }
    }
}

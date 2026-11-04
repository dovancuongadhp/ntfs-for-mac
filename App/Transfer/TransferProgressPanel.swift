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
            if progress.items.isEmpty && queue.history.isEmpty {
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
                if let detail = TransferText.detail(phase: queue.phase, lastStop: queue.lastStop, summary: queue.summary) {
                    // Over: what was copied and how long it took, or what to do about a halt.
                    Text(detail)
                } else {
                    Text("\(TransferText.size(progress.processedBytes)) of \(TransferText.size(progress.totalBytes))")
                    if queue.phase == .running {
                        if let seconds = progress.secondsRemaining {
                            Text("About \(TransferText.duration(seconds)) left")
                        }
                        // Speeds belong to a copy that is moving; paused or waiting on a question they are stale.
                        if progress.readRate > 0 || progress.writeRate > 0 {
                            Text("Read \(TransferText.rate(progress.readRate)) · Write \(TransferText.rate(progress.writeRate))")
                        }
                    }
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
        TransferText.headline(
            phase: queue.phase, lastStop: queue.lastStop, summary: queue.summary ?? progress.summary(),
            done: progress.doneCount, total: progress.fileCount)
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

    /// The latest copy, then the earlier ones still kept.
    private var visibleItems: [TransferItem] {
        (progress.items + queue.history).filter { item in
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
            Table(visibleItems) {
                TableColumn("Name") { item in NameCell(item: item).equatable() }
                    .width(min: 140, ideal: 220)
                TableColumn("From") { item in FolderCell(url: item.job.source.deletingLastPathComponent()).equatable() }
                    .width(min: 100, ideal: 220)
                TableColumn("To") { item in FolderCell(url: item.job.destination.deletingLastPathComponent()).equatable() }
                    .width(min: 100, ideal: 220)
                TableColumn("Size") { item in
                    Text(TransferText.size(item.job.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80, max: 110)
                TableColumn("Status") { item in StatusCell(item: item).equatable() }
                    .width(min: 70, ideal: 90, max: 120)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            let failed = queue.failedCount
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

/// The cells are Equatable, so a progress tick redraws only the rows whose item changed.
private struct NameCell: View, Equatable {
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
        }
        .help(item.job.name)
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
}

/// A folder path cut at the front, so the folder names nearest the file stay visible; the whole path on hover.
private struct FolderCell: View, Equatable {
    let url: URL

    var body: some View {
        Text(url.path)
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(.secondary)
            .help(url.path)
    }
}

private struct StatusCell: View, Equatable {
    let item: TransferItem

    var body: some View {
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

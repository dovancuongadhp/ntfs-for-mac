import NTFSTransfer
import SwiftUI

/// Under the two sides: how far along the copy is, how fast, which files are done, and which failed.
struct TransferProgressPanel: View {
    @Bindable var session: TransferSession
    /// Only the bar with its button and a one-line status shows, until the person opens it again.
    @Binding var collapsed: Bool
    @State private var filter = Filter.all
    /// Copies the person opened or closed; the others follow the default, only the newest open.
    @State private var expansion: [Int: Bool] = [:]
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
            bar
            if !collapsed {
                if queue.phase != .idle {
                    Divider()
                    summaryBlock
                }
                Divider()
                list
                if queue.failedCount > 0 {
                    Divider()
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    private var isEmpty: Bool { progress.items.isEmpty && queue.history.isEmpty }

    /// A copy under way, or halted waiting to resume, is kept until it ends.
    private var canClear: Bool { !isEmpty && (queue.phase == .idle || queue.phase == .finished) }

    /// Always there: the button that opens and closes the panel, what the copy is doing, and the options;
    /// open, also the filter and Clear.
    private var bar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Show progress" : "Hide progress")
            .accessibilityLabel(collapsed ? "Show progress" : "Hide progress")
            Text(isEmpty ? String(localized: "No copies yet") : statusText)
                .font(.headline)
                .lineLimit(1)
            if collapsed, queue.isBusy {
                ProgressView(value: progress.fraction).frame(width: 120)
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if collapsed, queue.failedCount > 0 {
                Label("Errors: \(queue.failedCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            if !collapsed {
                Picker("", selection: $filter) {
                    Text("All").tag(Filter.all)
                    Text("Copying").tag(Filter.copying)
                    Text("Errors").tag(Filter.errors)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Button("Clear") {
                    session.clearLog()
                    expansion = [:]
                }
                .controlSize(.small)
                .disabled(!canClear)
                .help("Empty the copy log")
            }
            optionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { withAnimation(.snappy) { collapsed.toggle() } }
    }

    // MARK: Summary

    /// One line while a copy runs, is halted or has just ended; nothing when idle.
    private var summaryBlock: some View {
        HStack(spacing: 12) {
            if queue.phase != .finished {
                ProgressView(value: progress.fraction).frame(width: 160)
            }
            Group {
                if let detail = TransferText.detail(phase: queue.phase, lastStop: queue.lastStop, summary: queue.summary) {
                    // Over: what was copied and how long it took, or what to do about a halt.
                    Text(detail).lineLimit(2)
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
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            controls
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        // Only copies kept from an earlier launch, nothing new yet.
        if queue.phase == .idle { return String(localized: "Earlier copies: \(queue.groups.count)") }
        return TransferText.headline(
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

    /// A copy and those of its files the filter lets through.
    private struct ShownCopy: Identifiable {
        let group: TransferGroup
        let files: [TransferItem]
        var id: Int { group.id }
    }

    /// Newest copy first; a copy with nothing left after the filter is left out.
    private func shown(_ groups: [TransferGroup]) -> [ShownCopy] {
        groups.compactMap { group in
            let files = group.progress.items.filter { item in
                guard !item.job.isDirectory else { return false }
                switch filter {
                case .all: return true
                case .copying: return item.state == .copying || item.state == .waiting
                case .errors: return item.failure != nil
                }
            }
            return files.isEmpty ? nil : ShownCopy(group: group, files: files)
        }
    }

    private func isExpanded(_ copy: ShownCopy, newest: Int?) -> Binding<Bool> {
        Binding(
            get: { expansion[copy.id] ?? (copy.id == newest) },
            set: { expansion[copy.id] = $0 })
    }

    private var list: some View {
        let groups = queue.groups
        let copies = shown(groups)
        let newest = groups.first?.id
        return Table(of: ProgressRow.self) {
            TableColumn("Name") { row in
                switch row {
                case .copy(let group): CopyNameCell(group: group).equatable()
                case .file(let item): NameCell(item: item).equatable()
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("From") { row in FolderCell(url: row.from, emphasized: row.isCopy).equatable() }
                .width(min: 100, ideal: 220)
            TableColumn("To") { row in FolderCell(url: row.to, emphasized: row.isCopy).equatable() }
                .width(min: 100, ideal: 220)
            TableColumn("Size") { row in
                Text(TransferText.size(row.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("Status") { row in
                switch row {
                case .copy(let group): CopyStatusCell(group: group).equatable()
                case .file(let item): StatusCell(item: item).equatable()
                }
            }
            .width(min: 70, ideal: 90, max: 120)
        } rows: {
            ForEach(copies) { copy in
                DisclosureTableRow(ProgressRow.copy(copy.group), isExpanded: isExpanded(copy, newest: newest)) {
                    ForEach(copy.files) { item in
                        TableRow(ProgressRow.file(item))
                    }
                }
            }
        }
        .overlay {
            if copies.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyMessage: LocalizedStringKey {
        switch filter {
        case .all: "Drag files between the two sides, or select files and press Copy."
        case .copying: "Nothing is being copied."
        case .errors: "No errors."
        }
    }

    // MARK: Footer

    /// Only while something failed.
    private var footer: some View {
        HStack {
            Label("Errors: \(queue.failedCount)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Spacer()
            if !queue.isBusy {
                Button("Retry Failed") { queue.retryFailed() }
            }
            Button("Export Error List…") { session.exportFailures() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A copy's heading row, or one of its files.
private enum ProgressRow: Identifiable {
    case copy(TransferGroup)
    case file(TransferItem)

    enum ID: Hashable {
        case copy(Int)
        case file(Int)
    }

    var id: ID {
        switch self {
        case .copy(let group): .copy(group.id)
        case .file(let item): .file(item.id)
        }
    }

    var isCopy: Bool {
        if case .copy = self { true } else { false }
    }

    var from: URL {
        switch self {
        case .copy(let group): group.from
        case .file(let item): item.job.source.deletingLastPathComponent()
        }
    }

    var to: URL {
        switch self {
        case .copy(let group): group.to
        case .file(let item): item.job.destination.deletingLastPathComponent()
        }
    }

    var size: Int64 {
        switch self {
        case .copy(let group): group.progress.totalBytes
        case .file(let item): item.job.size
        }
    }
}

/// When the copy started and how many files it has.
private struct CopyNameCell: View, Equatable {
    let group: TransferGroup

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            Text("Copy at \(group.started.formatted(date: .omitted, time: .standard))")
                .fontWeight(.semibold)
                .lineLimit(1)
            Text("Files: \(group.progress.fileCount)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch group.status {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .copying: ProgressView().controlSize(.small)
        case .over:
            if group.progress.failedCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}

private struct CopyStatusCell: View, Equatable {
    let group: TransferGroup

    var body: some View {
        switch group.status {
        case .waiting: Text("Waiting").foregroundStyle(.secondary)
        case .copying:
            Text(group.progress.fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        case .over:
            if group.progress.failedCount > 0 {
                Text("Errors: \(group.progress.failedCount)").foregroundStyle(.red)
            } else {
                Text("Done").foregroundStyle(.secondary)
            }
        }
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
    /// A copy's own folders, darker than those of its files.
    var emphasized = false

    var body: some View {
        Text(url.path)
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(emphasized ? .primary : .secondary)
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

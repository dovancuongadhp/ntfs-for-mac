import SwiftUI

struct FormatSheet: View {
    let model: AppModel
    let target: FormatTarget

    @Environment(\.dismiss) private var dismiss
    @State private var preparation: FormatPreparation?
    @State private var name: String
    @State private var fileSystem: FormatFileSystem
    @State private var scheme: PartitionScheme = .gpt
    @State private var clusterSize = 0
    @State private var quick = true
    @State private var showsAdvanced = false
    @State private var confirmation = ""
    @State private var phase: Phase = .editing

    private enum Phase: Equatable {
        case editing
        case running(FormatStage)
        case failed(String)
        case finished
    }

    private static let clusterSizes = [4096, 8192, 16384, 32768, 65536]

    init(model: AppModel, target: FormatTarget) {
        self.model = model
        self.target = target
        let prepared = model.prepareFormat(target)
        _preparation = State(initialValue: prepared)
        _name = State(initialValue: prepared?.suggestedName ?? "")
        _fileSystem = State(initialValue: prepared?.fileSystems.first ?? .exfat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preparation {
                content(preparation)
            } else {
                Text("This drive is no longer available.")
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .interactiveDismissDisabled(isRunning)
        .onChange(of: fileSystem) { _, newValue in
            if newValue == .apfs { scheme = .gpt }
        }
        .onChange(of: model.inventory.tree) {
            // A drive unplugged or swapped while the sheet is open must not be erased.
            if phase == .editing, let preparation, !model.isCurrent(preparation) {
                self.preparation = nil
            }
        }
    }

    @ViewBuilder
    private func content(_ preparation: FormatPreparation) -> some View {
        if preparation.target.isDisk {
            Text("Erase “\(preparation.displayName)”?").font(.title3.bold())
        } else {
            Text("Format “\(preparation.displayName)”?").font(.title3.bold())
        }

        WarningBox(preparation: preparation)

        if fileSystem == .ntfs {
            Group {
                if preparation.target.isDisk {
                    Text("You'll be asked for an administrator password to finish formatting as NTFS. If you cancel it, the drive stays exFAT.")
                } else {
                    Text("You'll be asked for an administrator password.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let block = preparation.block {
            Label(block.message, systemImage: "lock.fill").foregroundStyle(.secondary)
        }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                TextField("Name", text: $name).labelsHidden()
            }
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Picker("Format", selection: $fileSystem) {
                    ForEach(preparation.fileSystems) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if preparation.target.isDisk {
                GridRow {
                    Text("Scheme").foregroundStyle(.secondary)
                    Picker("Scheme", selection: $scheme) {
                        Text(PartitionScheme.gpt.label).tag(PartitionScheme.gpt)
                        Text(PartitionScheme.mbr.label).tag(PartitionScheme.mbr)
                    }
                    .labelsHidden()
                    .disabled(fileSystem == .apfs)
                }
            }
        }
        .disabled(phase != .editing)

        if fileSystem == .ntfs {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Cluster size", selection: $clusterSize) {
                        Text("Automatic").tag(0)
                        ForEach(Self.clusterSizes, id: \.self) { size in
                            Text(Int64(size).formatted(.byteCount(style: .memory))).tag(size)
                        }
                    }
                    Toggle("Quick format", isOn: $quick)
                    if !quick {
                        Text("A full format writes zeros over the whole partition and can take a long time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .disabled(phase != .editing)
        }

        if case .failure(let error) = nameCheck, phase == .editing {
            Text(error.message).font(.caption).foregroundStyle(.red)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Type “\(preparation.displayName)” to confirm").font(.callout)
            TextField(preparation.displayName, text: $confirmation)
                .disabled(phase != .editing)
        }

        switch phase {
        case .editing:
            EmptyView()
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage.label)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .finished:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }

        HStack {
            Spacer()
            switch phase {
            case .finished:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            case .editing, .running:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Button("Erase and Format", role: .destructive) { start(preparation) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canStart(preparation))
            }
        }
    }

    private var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    private var nameCheck: Result<String, VolumeNameError> {
        VolumeNameRule.validate(name, for: fileSystem)
    }

    private func canStart(_ preparation: FormatPreparation) -> Bool {
        guard phase == .editing, preparation.block == nil, preparation.fileSystems.contains(fileSystem),
              case .success = nameCheck
        else { return false }
        return FormatSafety.isConfirmed(confirmation, displayName: preparation.displayName)
    }

    private func start(_ preparation: FormatPreparation) {
        guard case .success(let finalName) = nameCheck else { return }
        let options = FormatOptions(
            name: finalName, fileSystem: fileSystem, scheme: scheme,
            clusterSize: fileSystem == .ntfs && clusterSize != 0 ? clusterSize : nil,
            quick: fileSystem != .ntfs || quick)
        phase = .running(.checking)
        Task {
            do {
                try await model.format(preparation, options: options) { stage in
                    phase = .running(stage)
                }
                phase = .finished
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

private struct WarningBox: View {
    let preparation: FormatPreparation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline).bold()
            Text(detail)
            if preparation.target.isDisk, !preparation.affected.isEmpty {
                Text("Erases: \(preparation.affected.map(\.name).joined(separator: ", "))")
            }
            if !preparation.unaffected.isEmpty {
                Text("Not affected: \(preparation.unaffected.map(\.name).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            ForEach(preparation.warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.callout)
        .foregroundStyle(Color.red)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private var headline: String {
        let name = preparation.displayName
        if let used = preparation.usedBytes {
            return String(localized: "All \(used.formatted(.byteCount(style: .file))) of data on “\(name)” will be erased permanently.")
        }
        return String(localized: "Everything on “\(name)” will be erased permanently.")
    }

    private var detail: String {
        let size = preparation.device.size.formatted(.byteCount(style: .file))
        if preparation.target.isDisk {
            return String(localized: "Whole drive \(preparation.device.bsdName) · \(size) · every partition and volume on it.")
        }
        return String(localized: "Partition \(preparation.device.bsdName) · \(size) · on \(preparation.disk.name).")
    }
}

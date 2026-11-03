import SwiftUI

struct DiskDetailView: View {
    let model: AppModel
    let disk: PhysicalDisk

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    DriveIcon(
                        systemImage: disk.isInternal ? "internaldrive.fill" : "externaldrive.fill",
                        colors: [Color(white: 0.45), Color(white: 0.2)])
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(disk.name).font(.title2.bold()).lineLimit(1)
                            if model.isProtected(disk) {
                                Badge(text: String(localized: "Protected"), tint: .secondary)
                            }
                        }
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Partition map").font(.headline)
                    SegmentedBar(segments: segments, height: 22)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Array(disk.mapPartitions.enumerated()), id: \.element.id) { index, partition in
                            LegendItem(
                                color: color(index, partition),
                                text: "\(partition.name) · \(partition.fileSystem.label) · \(partition.size.formatted(.byteCount(style: .file)))")
                        }
                    }
                }

                InfoGrid(rows: [
                    InfoRow(label: String(localized: "Capacity"), value: disk.size.formatted(.byteCount(style: .file))),
                    InfoRow(label: String(localized: "Connection"), value: disk.connection ?? "—"),
                    InfoRow(label: String(localized: "Partition scheme"), value: disk.scheme.label),
                    InfoRow(label: String(localized: "Partitions"), value: String(disk.sidebarPartitions.count)),
                    InfoRow(label: String(localized: "Device"), value: disk.bsdName),
                ])
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        [
            disk.isInternal ? String(localized: "Internal drive") : String(localized: "External drive"),
            disk.connection,
            disk.scheme.label,
            disk.bsdName,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var segments: [SegmentedBar.Segment] {
        disk.mapPartitions.enumerated().map { index, partition in
            SegmentedBar.Segment(
                id: partition.bsdName,
                fraction: disk.size == 0 ? 0 : Double(partition.size) / Double(disk.size),
                color: color(index, partition))
        }
    }

    private func color(_ index: Int, _ partition: Partition) -> Color {
        partition.isHidden && !partition.isAPFSStore ? .gray : Self.palette[index % Self.palette.count]
    }
}

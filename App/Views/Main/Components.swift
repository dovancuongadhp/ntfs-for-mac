import SwiftUI

struct Badge: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A rounded bar split into coloured segments: used space, or a partition map.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = segments.count > 1 ? 2 : 0
            let available = max(0, proxy.size.width - spacing * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    segment.color.frame(width: max(3, available * min(max(segment.fraction, 0), 1)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.15))
        .clipShape(.rect(cornerRadius: 3))
    }
}

struct InfoRow: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

/// Facts about a drive. Two columns when the page is wide enough to hold them
/// without cutting a value short, one column otherwise.
struct InfoGrid: View {
    let rows: [InfoRow]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                    GridRow {
                        cell(rows[index])
                        if index + 1 < rows.count {
                            cell(rows[index + 1])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            VStack(spacing: 10) {
                ForEach(rows) { cell($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ row: InfoRow) -> some View {
        HStack {
            Text(row.label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(row.value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The warnings at the top of a page. They are part of the page's form: stacked
/// above a form, they made the column taller than the window.
struct PageBanners: View {
    let model: AppModel
    var showsExtensionWarning = true

    var body: some View {
        if showsExtensionWarning, model.extensionStatus.isEnabled == false {
            Section {
                ExtensionDisabledBanner(model: model)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        if let error = model.lastError {
            Section {
                ErrorBanner(message: error) { model.dismissError() }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }
}

extension View {
    /// The same grouped-form metrics for a drive page and Settings. It fills the
    /// detail column, so resizing the window resizes the page with it.
    func detailColumn() -> some View {
        formStyle(.grouped)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.yellow.opacity(0.12))
    }
}

struct ExtensionDisabledBanner: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The file system extension is turned off", systemImage: "exclamationmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Drives stay read-only until you turn on NTFS for Mac in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { model.extensionStatus.openSystemSettings() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

struct DriveIcon: View {
    let systemImage: String
    let colors: [Color]

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// Marks a feature that is still being tested.
struct BetaBadge: View {
    var body: some View {
        Text(verbatim: "BETA")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(.orange)
            .background(.orange.opacity(0.2), in: .capsule)
            .accessibilityLabel("Beta")
    }
}

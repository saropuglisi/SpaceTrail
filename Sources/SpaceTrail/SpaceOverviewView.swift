import Charts
import SpaceTrailCore
import SwiftUI

struct SpaceOverviewView: View {
    let model: DashboardModel

    var body: some View {
        if let overview = model.overview, model.overviewIncludesDetails {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let space = model.volumeSpace { capacity(space) }
                        StorageHistoryView(history: overview.history).equatable()
                        let layout = geometry.size.width >= 835
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                        layout {
                            ranking("Largest Files", entries: overview.largeFiles, folders: false)
                            ranking("Folders to Explore", entries: overview.largeFolders, folders: true)
                        }
                    }
                    .padding(.horizontal, StorageStyle.inset)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if model.overview != nil {
            ProgressView().accessibilityLabel("Loading Storage Overview")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            IndexPlaceholder(state: model.state, hasError: model.connectionError != nil || model.brokerProblem != nil)
        }
    }

    private func capacity(_ sample: VolumeSpace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.volumeName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(StorageStyle.size(sample.capacity) + " total")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let fraction = sample.capacity > 0 ? Double(sample.used) / Double(sample.capacity) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(StorageStyle.accent)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            HStack {
                legend("\(StorageStyle.size(sample.used)) used", tint: StorageStyle.accent)
                Spacer()
                legend("\(StorageStyle.size(sample.available)) free", tint: Color.secondary.opacity(0.35))
            }
            .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legend(_ title: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    private func ranking(_ title: String, entries: [StorageEntry], folders: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            Text(folders ? "One folder per branch" : "By disk usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            if entries.isEmpty {
                Text("No indexed items.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                Divider()
                Button {
                    if folders { model.openFolder(entry.id) }
                    else { model.reveal(entry.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: folders ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                            if let parent = entry.parent {
                                Text(StorageStyle.location(parent))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        DiskUsageLabel(usage: model.diskUsage(for: entry)).font(.callout)
                        Image(systemName: folders ? "chevron.right" : "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folders ? "Browse Folder" : "Show in Finder")
                .accessibilityHint(folders ? "Opens the folder" : "Shows the file in Finder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StorageHistoryView: View, Equatable {
    let history: [StorageSample]
    @State private var days = 7
    @State private var dateSelection: Date?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.history == rhs.history }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let samples = history.filter { $0.date >= cutoff }
        let active = dateSelection.flatMap { date in
            samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Storage History").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Range", selection: $days) {
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                    Text("90 Days").tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .onChange(of: days) { _, _ in dateSelection = nil }
            }
            if samples.count < 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Storage History Is Building").font(.subheadline.weight(.medium))
                    Text("The chart appears once SpaceTrail has data from two different hours.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                .padding(.horizontal, 14)
                .background(.quaternary.opacity(0.27), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(active.map {
                    let date = $0.date.formatted(.dateTime.day().month().hour().minute().locale(StorageStyle.locale))
                    return "\(date) · \(StorageStyle.size($0.used)) used"
                } ?? "Measured disk usage")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Chart {
                    ForEach(samples) { sample in
                        LineMark(x: .value("Date", sample.date), y: .value("Used Space", sample.used))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(StorageStyle.accent)
                            .accessibilityLabel(sample.date.formatted(StorageStyle.dateAndTime))
                            .accessibilityValue(StorageStyle.size(sample.used))
                    }
                    if let active {
                        RuleMark(x: .value("Selected Date", active.date)).foregroundStyle(.secondary.opacity(0.35))
                        PointMark(x: .value("Selected Date", active.date), y: .value("Used Space", active.used))
                            .foregroundStyle(StorageStyle.accent)
                            .symbolSize(32)
                    }
                }
                .chartYScale(domain: chartDomain(samples))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) { Text(StorageStyle.size(bytes)) }
                            else if let bytes = value.as(Double.self) { Text(StorageStyle.size(Int64(bytes))) }
                        }
                    }
                }
                .chartXSelection(value: $dateSelection)
                .frame(height: 165)
                .accessibilityLabel("Disk Usage Chart")
            }
        }
    }

    private func chartDomain(_ samples: [StorageSample]) -> ClosedRange<Int64> {
        let minimum = samples.map(\.used).min() ?? 0
        let maximum = samples.map(\.used).max() ?? 0
        let margin = max((maximum - minimum) / 6, 100_000_000)
        return max(0, minimum - margin)...(maximum + margin)
    }
}

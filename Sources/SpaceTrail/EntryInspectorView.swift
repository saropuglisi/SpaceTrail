import AppKit
import SpaceTrailCore
import SwiftUI

struct EntryInspectorView: View {
    let entry: StorageEntry
    let model: DashboardModel
    let compact: Bool
    let openPreview: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    model.showsDetails = false
                } label: {
                    Label("Close Details", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Close Details")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    let layout = compact ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    layout {
                        if let url = model.previewURL(for: entry), entry.hasThumbnail {
                            Button { openPreview(url) } label: {
                                FileThumbnail(entry: entry, size: .cover, source: url)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: compact ? 86 : 148)
                                    .padding(7)
                                    .background(.quaternary.opacity(0.36), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .frame(width: compact ? 124 : nil)
                            .accessibilityLabel("Open Preview")
                            .help("Open in Quick Look")
                        }
                        statistics
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(StorageStyle.location(entry.id.path))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(entry.displayPath)
                Spacer(minLength: 0)
                Button {
                    copyEntryPath(entry)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy Path")
            }
        }
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 9) {
            if entry.id.path != entry.id.tree.root {
                let usage = model.diskUsage(for: entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text("On Disk").font(.subheadline).foregroundStyle(.secondary)
                    Text(usage.accessibleText)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .help(usage.explanation)
                }
                .accessibilityElement(children: .combine)
                if let estimate = entry.footprint {
                    if estimate.sharedBytes > 0 {
                        Text("\(StorageStyle.size(estimate.sharedBytes)) shared with other items.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if estimate.incomplete {
                        Text(entry.isFolder ? "Some blocks or paths could not be measured." : "Some blocks may be shared with other files.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            stat("Logical Size", StorageStyle.exactSize(entry.logical))
            if entry.isFolder { stat("Items", StorageStyle.count(entry.files)) }
            stat("Modified", entry.modified.formatted(StorageStyle.dateAndTime))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.callout)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(.secondary)
                Text(value).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

func copyEntryPath(_ entry: StorageEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.displayPath, forType: .string)
}

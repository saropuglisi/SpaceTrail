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
                Text("Dettagli")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    model.showsDetails = false
                } label: {
                    Label("Chiudi pannello", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Chiudi pannello")
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
                            .accessibilityLabel("Apri anteprima")
                            .help("Apri anteprima Quick Look")
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
                    Label("Copia percorso", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copia percorso")
            }
        }
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 9) {
            if entry.id.path != entry.id.tree.root {
                let usage = model.diskUsage(for: entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Su disco").font(.subheadline).foregroundStyle(.secondary)
                    Text(usage.accessibleText)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .help(usage.explanation)
                }
                .accessibilityElement(children: .combine)
                if let estimate = entry.footprint {
                    if estimate.sharedBytes > 0 {
                        Text("\(StorageStyle.size(estimate.sharedBytes)) condivisi con altre voci.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if estimate.incomplete {
                        Text(entry.isFolder ? "Alcuni blocchi o percorsi non sono misurabili." : "Alcuni blocchi possono essere condivisi.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            stat("Dimensione logica", StorageStyle.exactSize(entry.logical))
            if entry.isFolder { stat("Elementi", entry.files.formatted()) }
            stat("Modificato", entry.modified.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
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

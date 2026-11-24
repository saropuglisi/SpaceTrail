import QuickLook
import SpaceTrailCore
import SwiftUI

private struct MapItem: Identifiable {
    let entry: StorageEntry
    let usage: DiskUsage
    let tint: Color

    var id: EntryKey { entry.id }
    var bytes: Int64 { usage.bytes ?? 0 }
    var symbol: String { entry.isFolder ? "folder" : "doc" }
}

struct StorageMapView: View {
    private struct Request: Equatable {
        let folder: EntryKey
        let revision: String?
        let retry: Int
    }

    private struct Snapshot {
        let folder: EntryKey
        let page: MapPage
    }

    private static let tones: [SIMD3<Double>] = [
        SIMD3(0.22, 0.29, 0.53),
        SIMD3(0.12, 0.37, 0.52),
        SIMD3(0.09, 0.42, 0.37),
        SIMD3(0.45, 0.39, 0.17),
        SIMD3(0.61, 0.29, 0.20)
    ]

    let model: DashboardModel
    @AppStorage("map.proportionalArea") private var proportionalArea = false
    @State private var snapshot: Snapshot?
    @State private var selection: EntryKey?
    @State private var hovered: EntryKey?
    @State private var preview: URL?
    @State private var loadError: String?
    @State private var retry = 0
    @AccessibilityFocusState private var locationFocused: Bool

    var body: some View {
        let request = Request(folder: model.mapFolder, revision: model.revision, retry: retry)
        VStack(alignment: .leading, spacing: 12) {
            navigation
            if request.revision == nil {
                IndexPlaceholder(state: model.state, hasError: model.connectionError != nil || model.brokerProblem != nil)
            } else if let snapshot, snapshot.folder == request.folder {
                if let loadError {
                    HStack {
                        Label("Ultima mappa disponibile", systemImage: "exclamationmark.circle")
                        Spacer()
                        Button("Riprova") { retry += 1 }
                    }
                    .font(.callout)
                    .help(loadError)
                }
                contents(snapshot.page)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Mappa non disponibile", systemImage: "exclamationmark.circle")
                } description: {
                    Text("Riprova a leggere l’indice.")
                } actions: {
                    Button("Riprova") { retry += 1 }.help(loadError)
                }
            } else {
                ProgressView("Caricamento mappa")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.removalInProgress != nil || model.deletionReport != nil {
                Divider()
                DeletionStatusView(model: model)
            }
        }
        .padding(.horizontal, StorageStyle.inset)
        .padding(.bottom, 14)
        .task(id: request) { await load(request) }
        .onChange(of: model.mapFolder) { _, _ in
            selection = nil
            hovered = nil
            loadError = nil
            locationFocused = true
        }
        .quickLookPreview($preview)
    }

    private var navigation: some View {
        let trail = model.trail(to: model.mapFolder)
        let previous = trail.dropLast().last?.1
        let name = model.mapFolder == SpaceTrailPaths.personalFolder ? "Cartella personale" : trail.last?.0 ?? model.volumeName
        return HStack(spacing: 9) {
            Button {
                if let previous { model.openMap(previous) }
            } label: {
                Label("Cartella superiore", systemImage: "chevron.up").labelStyle(.iconOnly)
            }
            .disabled(previous == nil)
            .help("Risali di un livello")

            Menu {
                Button(model.volumeName) {
                    model.openMap(EntryKey(tree: .data, path: VolumeTree.data.root))
                }
                if let home = SpaceTrailPaths.personalFolder {
                    Button("Cartella personale") { model.openMap(home) }
                }
                if !model.isFixture {
                    Button("Sistema macOS") { model.openMap(EntryKey(tree: .system, path: "/")) }
                }
                if trail.count > 2 {
                    Divider()
                    ForEach(trail.dropFirst().dropLast(), id: \.1) { title, key in
                        Button(title) { model.openMap(key) }
                    }
                }
            } label: {
                Label("Posizione", systemImage: "folder")
            }
            .fixedSize()
            .help("Scegli il percorso da rappresentare")

            Text(name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(StorageStyle.location(model.mapFolder.path))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($locationFocused)
            Spacer(minLength: 8)
            Picker("Area dei riquadri", selection: $proportionalArea) {
                Text("Area bilanciata").tag(false)
                Text("Area proporzionale").tag(true)
            }
            .labelsHidden()
            .fixedSize()
            .help("La vista bilanciata distribuisce un quinto dell’area per rendere visibili le voci piccole.")
            Button {
                model.openFolder(model.mapFolder)
            } label: {
                Label("Apri in Cartelle", systemImage: "list.bullet")
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func contents(_ page: MapPage) -> some View {
        let rows = page.contents.rows.filter { !model.hidesRemovedEntry($0) }
        if rows.isEmpty {
            ContentUnavailableView("Nessun elemento in mappa", systemImage: "folder",
                                   description: Text("Qui non risultano elementi indicizzati."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let largest = rows.map { mapUsage($0).bytes ?? 0 }.max() ?? 0
            let items = mapItems(rows, largest: largest)
            let children = page.previews.mapValues { entries in
                mapItems(entries.filter { !model.hidesRemovedEntry($0) }, largest: largest)
            }
            let active = items.first { $0.id == selection } ?? children.values.lazy.joined().first { $0.id == selection }
            GeometryReader { geometry in
                if geometry.size.width >= 680 {
                    HStack(alignment: .top, spacing: 18) {
                        map(items, children: children)
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            detail(active)
                            Divider()
                            ScrollView { ranking(items, active: active, hasMore: page.contents.hasMore) }
                        }
                        .frame(width: 246)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                map(items, children: children).frame(height: max(200, geometry.size.height * 0.63))
                                Divider()
                                ranking(items, active: active, hasMore: page.contents.hasMore)
                            }
                        }
                        if let active {
                            Divider()
                            detail(active)
                        }
                    }
                }
            }
        }
    }

    private func mapUsage(_ entry: StorageEntry) -> DiskUsage {
        model.diskUsage(for: entry, includeSavedMeasurement: true)
    }

    private func mapItems(_ entries: [StorageEntry], largest: Int64) -> [MapItem] {
        entries.map { entry in
            let usage = mapUsage(entry)
            return MapItem(entry: entry, usage: usage, tint: Self.tint(bytes: usage.bytes ?? 0, largest: largest))
        }
    }

    private static func tint(bytes: Int64, largest: Int64) -> Color {
        let fraction = largest > 0 ? min(1, max(0, Double(bytes) / Double(largest))) : 0
        // Logarithmic spacing keeps the lighter end legible on very uneven disks.
        let position = log2(1 + 63 * fraction) / 6 * Double(tones.count - 1)
        let index = min(Int(position), tones.count - 2)
        let blend = position - Double(index)
        let rgb = tones[index] + (tones[index + 1] - tones[index]) * blend
        return Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    private func map(_ items: [MapItem], children: [EntryKey: [MapItem]]) -> some View {
        let tiles = items.filter { $0.bytes > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            if tiles.isEmpty {
                ContentUnavailableView("Nessun riquadro ancora", systemImage: "square.split.2x2",
                                       description: Text("La mappa mostra gli elementi con una misura su disco positiva."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 9))
            } else {
                GeometryReader { geometry in
                    let frames = TreemapLayout.rectangles(for: tiles.map(\.bytes), in: geometry.size,
                                                          balanced: !proportionalArea)
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.quaternary)
                        ForEach(Array(zip(tiles, frames)), id: \.0.id) { item, frame in
                            if frame.width >= 3, frame.height >= 3 {
                                let rect = frame.insetBy(dx: 1, dy: 1)
                                Group {
                                    let previews = children[item.id, default: []].filter { $0.bytes > 0 }
                                    if rect.width >= 155, rect.height >= 105, !previews.isEmpty {
                                        folderTile(item, children: previews, size: rect.size)
                                    } else {
                                        tile(item, size: rect.size)
                                    }
                                }
                                .position(x: rect.midX, y: rect.midY)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Mappa dello spazio su disco")
                }
            }
            HStack(spacing: 9) {
                HStack(spacing: 6) {
                    Text("Più leggero")
                    Capsule().fill(LinearGradient(
                        colors: Self.tones.map { Color(red: $0.x, green: $0.y, blue: $0.z) },
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: 49, height: 6)
                    .accessibilityHidden(true)
                    Text("Più pesante")
                }
                .help("Il colore confronta la misura su disco con la voce più pesante di questa mappa.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("I colori vanno dal blu per le voci leggere al rame per quelle pesanti")
                Spacer(minLength: 0)
                Text("≈ Stima  ·  ≥ Almeno")
                    .help("Le cifre mostrano la misura su disco. Nei riquadri grandi vedi le voci principali della cartella.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func folderTile(_ item: MapItem, children: [MapItem], size: CGSize) -> some View {
        let inset: CGFloat = 5
        let header: CGFloat = 34
        let interior = CGSize(width: size.width - inset * 2, height: size.height - header - inset)
        let rectangles = TreemapLayout.rectangles(for: children.map(\.bytes), in: interior, balanced: !proportionalArea)
        return VStack(spacing: 0) {
            tileButton(item) {
                HStack(spacing: 8) {
                    Label(item.entry.name, systemImage: item.symbol)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(item.usage.text).font(.caption.monospacedDigit().weight(.semibold)).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(width: size.width, height: header)
                .contentShape(Rectangle())
            }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.black.opacity(0.18))
                ForEach(Array(zip(children, rectangles)), id: \.0.id) { child, frame in
                    if frame.width >= 3, frame.height >= 3 {
                        let rect = frame.insetBy(dx: 1, dy: 1)
                        tile(child, size: rect.size).position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: interior.width, height: interior.height)
            .clipped()
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(item.tint)
        .overlay {
            Rectangle().strokeBorder(.white.opacity(selection == item.id ? 1 : hovered == item.id ? 0.6 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private func tile(_ item: MapItem, size: CGSize) -> some View {
        let large = size.width >= 139 && size.height >= 100
        let selected = selection == item.id
        return tileButton(item) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(item.tint)
                if size.width >= 74, size.height >= 41 {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(item.entry.name, systemImage: item.symbol)
                            .font(large ? .headline : .caption.weight(.semibold))
                            .lineLimit(1)
                        if large { Spacer(minLength: 0) }
                        Text(item.usage.text)
                            .font(large ? .title2.monospacedDigit().weight(.semibold) : .caption2.monospacedDigit())
                            .lineLimit(1)
                    }
                    .padding(large ? 13 : 6)
                }
                Rectangle().strokeBorder(.white.opacity(selected ? 1 : hovered == item.id ? 0.60 : 0),
                                         lineWidth: selected ? 2.5 : 1)
            }
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
        }
    }

    private func tileButton<T: View>(_ item: MapItem, @ViewBuilder label: () -> T) -> some View {
        Button { selection = item.id } label: { label() }
        .buttonStyle(.plain)
        .onHover { highlight(item, entering: $0) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if item.entry.isFolder { model.openMap(item.id) } })
        .contextMenu { actions(for: item) }
        .help("\(item.entry.name) · \(item.usage.text)")
        .accessibilityLabel(item.entry.name)
        .accessibilityValue(item.usage.accessibleText)
        .accessibilityAddTraits(selection == item.id ? .isSelected : [])
    }

    private func detail(_ item: MapItem?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item {
                Label(item.entry.name, systemImage: item.symbol)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .help(item.entry.name)
                Text(StorageStyle.location(item.id.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    DiskUsageLabel(usage: item.usage).font(.callout.weight(.medium))
                    if model.indexAccess?.includes(item.id) == false {
                        Label("Dati salvati", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if FileDeletion.isProtected(item.id) {
                        Label("Posizione protetta", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if item.entry.isFolder {
                        Button("Esplora cartella") { model.openMap(item.id) }
                            .keyboardShortcut(.return, modifiers: [])
                    } else if let url = model.previewURL(for: item.entry) {
                        Button("Anteprima") { preview = url }
                            .keyboardShortcut(.space, modifiers: [])
                    }
                    Menu { actions(for: item) } label: {
                        Label("Azioni", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .fixedSize()
                    .help("Azioni per \(item.entry.name)")
                }
                .controlSize(.small)
            } else {
                Text("Seleziona un elemento per vedere i dettagli.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(for item: MapItem) -> some View {
        if item.entry.isFolder {
            Button("Esplora in Mappa") { model.openMap(item.id) }
            Button("Apri in Cartelle") { model.openFolder(item.id) }
            Button("Apri nel Finder") { model.openFolderInFinder(item.id) }
        } else {
            if let url = model.previewURL(for: item.entry) { Button("Anteprima") { preview = url } }
            Button("Mostra nel Finder") { model.reveal(item.id) }
        }
        Button("Copia percorso") { copyEntryPath(item.entry) }
        if FileDeletion.canMoveToTrash(item.entry, access: .complete) {
            let source = RemovalSource.map(model.mapFolder)
            Divider()
            Button("Sposta nel Cestino", role: .destructive) {
                Task {
                    await model.remove([item.entry], by: .trash, from: source)
                    if model.hidesRemovedEntry(item.entry) && selection == item.id { selection = nil }
                }
            }
            .disabled(!model.canRemove([item.entry], by: .trash, from: source))
        }
    }

    private func ranking(_ items: [MapItem], active: MapItem?, hasMore: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(hasMore ? "Elementi più grandi" : "In questa cartella")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            ForEach(items) { item in
                let selected = selection == item.id
                let highlighted = hovered == item.id || active?.entry.parent == item.id.path
                Button { selection = item.id } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(item.bytes > 0 ? Color.primary : Color.secondary)
                            .accessibilityHidden(true)
                        Text(item.entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        DiskUsageLabel(usage: item.usage)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(selected ? 0.22 : highlighted ? 0.12 : 0),
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { highlight(item, entering: $0) }
                .contextMenu { actions(for: item) }
                .accessibilityLabel(item.entry.name)
                .accessibilityValue(item.usage.accessibleText)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func highlight(_ item: MapItem, entering: Bool) {
        if entering { hovered = item.id }
        else if hovered == item.id { hovered = nil }
    }

    private func load(_ request: Request) async {
        guard request.revision != nil else { return }
        do {
            let page = try await model.mapPage(in: request.folder)
            guard !Task.isCancelled, request.folder == model.mapFolder else { return }
            if snapshot?.folder != request.folder || snapshot?.page != page {
                snapshot = Snapshot(folder: request.folder, page: page)
            }
            if !page.contents.rows.contains(where: { $0.id == selection }) &&
                !page.previews.values.joined().contains(where: { $0.id == selection }) { selection = nil }
            loadError = nil
        } catch {
            if !Task.isCancelled, request.folder == model.mapFolder { loadError = error.localizedDescription }
        }
    }
}

import AppKit
import QuickLook
import SpaceTrailCore
import SwiftUI

private enum BrowserLayout: String, CaseIterable, Identifiable {
    case list, compact, grid

    var id: Self { self }

    var title: String {
        switch self {
        case .list: return "List"
        case .compact: return "Compact"
        case .grid: return "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .list: return "list.bullet.rectangle"
        case .compact: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

private extension EntrySort {
    var title: String {
        switch self {
        case .name: return "Name"
        case .logical: return "Logical Size"
        case .allocated: return "Disk Usage"
        case .modified: return "Modified"
        }
    }

    func comparator(_ order: SortOrder) -> KeyPathComparator<StorageEntry> {
        switch self {
        case .name: return KeyPathComparator(\StorageEntry.name, order: order)
        case .logical: return KeyPathComparator(\StorageEntry.logical, order: order)
        case .allocated: return KeyPathComparator(\StorageEntry.diskBytes, order: order)
        case .modified: return KeyPathComparator(\StorageEntry.modified, order: order)
        }
    }
}

private struct SearchToolbarLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = measure(width: proposal.width, subviews: subviews)
        let height = layout.stacked ? layout.input.height + spacing + layout.options.height
            : max(layout.input.height, layout.options.height)
        return CGSize(width: layout.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = measure(width: bounds.width, subviews: subviews)
        let inputY = layout.stacked ? bounds.minY : bounds.midY - layout.input.height / 2
        subviews[0].place(at: CGPoint(x: bounds.minX, y: inputY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: layout.input.width, height: layout.input.height))
        let optionsX = layout.stacked ? bounds.minX : bounds.maxX - layout.options.width
        let optionsY = layout.stacked ? bounds.minY + layout.input.height + spacing : bounds.midY - layout.options.height / 2
        subviews[1].place(at: CGPoint(x: optionsX, y: optionsY), anchor: .topLeading, proposal: .unspecified)
    }

    private func measure(width proposedWidth: CGFloat?, subviews: Subviews)
        -> (width: CGFloat, input: CGSize, options: CGSize, stacked: Bool) {
        let options = subviews[1].sizeThatFits(.unspecified)
        let width = proposedWidth ?? subviews[0].sizeThatFits(.unspecified).width + spacing + options.width
        let stacked = width < 315 + spacing + options.width
        let inputWidth = stacked ? width : width - spacing - options.width
        let input = subviews[0].sizeThatFits(ProposedViewSize(width: inputWidth, height: nil))
        return (width, input, options, stacked)
    }
}

struct FileBrowserView: View {
    private struct Load: Equatable {
        let page: PageRequest
        let hasIndex: Bool
        let thumbnails: FileThumbnail.Size?
        let scale: CGFloat
        let access: ThumbnailAccess?
    }

    @Bindable var model: DashboardModel
    @AppStorage("browser.files.layout") private var filesLayout: BrowserLayout = .list
    @AppStorage("browser.folders.layout") private var foldersLayout: BrowserLayout = .list
    @AppStorage("browser.search.layout") private var searchLayout: BrowserLayout = .grid
    @State private var previewURL: URL?
    @State private var previewAccessError: String?
    @State private var showsPreviewAccessError = false
    @State private var deletion: DeletionSelection?
    @State private var gridAnchor: EntryKey?
    @Environment(\.displayScale) private var displayScale
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocus: EntryKey?

    private var folders: Bool { model.activeSection == .folders }
    private var global: Bool { model.activeSection == .search }
    private var searchThumbnailSize: FileThumbnail.Size? {
        switch searchLayout {
        case .grid: return .cover
        case .list: return .row
        case .compact: return nil
        }
    }
    private var thumbnailScale: CGFloat { min(2, max(1, displayScale)) }
    private var searchReady: Bool {
        model.lastRequest?.withoutRevision == model.request.withoutRevision &&
            model.preparedThumbnailSize == searchThumbnailSize && model.preparedThumbnailScale == thumbnailScale &&
            model.preparedThumbnailAccess == model.thumbnailAccess
    }

    private var layout: Binding<BrowserLayout> {
        if global { return $searchLayout }
        return folders ? $foldersLayout : $filesLayout
    }

    private var search: Binding<String> {
        if global { return $model.globalSearch }
        return folders ? $model.folderSearch : $model.fileSearch
    }

    private var sort: Binding<[KeyPathComparator<StorageEntry>]> {
        if global { return $model.globalOrder }
        return folders ? $model.folderOrder : $model.fileOrder
    }

    private var scopeLabel: String {
        if global { return "Search Results" }
        return folders ? "Folder Contents" : "All Files"
    }

    var body: some View {
        let request = model.request
        let job = Load(page: global ? request.withoutRevision : request, hasIndex: request.revision != nil,
                       thumbnails: global ? searchThumbnailSize : nil, scale: global ? thumbnailScale : 1,
                       access: global ? model.thumbnailAccess : nil)
        VStack(spacing: 0) {
            actions
                .padding(.horizontal, StorageStyle.inset)
                .padding(.bottom, 10)
            if folders, model.canOfferPreviewAccess(in: model.folder), model.rows.contains(where: \.hasThumbnail) {
                previewAccessNotice
            }
            Divider()
            browserArea
        }
        .task(id: job) { await load(job) }
        .onChange(of: search.wrappedValue) { _, value in
            if !global { model.resetPage() }
            else if value.isEmpty, !model.submittedSearch.isEmpty { model.clearSearch() }
        }
        .onChange(of: sort.wrappedValue) { _, _ in model.resetPage() }
        .onChange(of: model.searchFilters) { _, _ in if global { model.applySearchFilters() } }
        .onChange(of: model.selection) { _, keys in
            if keys.isEmpty { gridAnchor = nil }
            else { searchFocused = false }
        }
        .quickLookPreview($previewURL)
        .alert("Previews", isPresented: $showsPreviewAccessError, presenting: previewAccessError) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in Text(message) }
        .sheet(item: $deletion) { selection in
            ConfirmDeletionView(entries: selection.entries) {
                deletion = nil
                Task { await model.remove(selection.entries, by: .permanent) }
            }
        }
    }

    private var previewAccessNotice: some View {
        HStack(spacing: 9) {
            Label("Previews Require Folder Access", systemImage: "lock")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Allow Previews…") { requestPreviews(in: model.folder) }
                .help("Select this folder to show previews of its files")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, StorageStyle.inset)
        .padding(.bottom, 10)
    }

    private func requestPreviews(in folder: EntryKey) {
        Task {
            if let error = await model.choosePreviewFolder(folder) {
                previewAccessError = error
                showsPreviewAccessError = true
            }
        }
    }

    private func load(_ job: Load) async {
        guard job.hasIndex else { return }
        guard job.page.scope == .search else {
            await model.load(job.page)
            return
        }
        guard !job.page.search.isEmpty else { return }
        // Let a submitted page finish even if the broker commits another update.
        var lastRevision: String?
        while !Task.isCancelled, model.request.withoutRevision == job.page {
            let request = model.request
            if request.revision != lastRevision {
                await model.load(request, thumbnailSize: job.thumbnails, thumbnailScale: job.scale)
                lastRevision = request.revision
            }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
    }

    private var browserArea: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 875
            let arrangement = compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            arrangement {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.revision != nil, !global || searchReady,
                       !model.rows.isEmpty || (folders && model.folderInfo != nil) {
                        Divider()
                        footer
                            .padding(.horizontal, StorageStyle.inset)
                            .padding(.vertical, 7)
                    }
                    if model.removalInProgress != nil || model.deletionReport != nil {
                        Divider()
                        DeletionStatusView(model: model)
                            .padding(.horizontal, StorageStyle.inset)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.showsDetails, let entry = model.inspectedEntry {
                    Divider()
                    EntryInspectorView(entry: entry, model: model, compact: compact) { previewURL = $0 }
                        .frame(width: compact ? nil : 306, height: compact ? min(218, geometry.size.height * 0.52) : nil)
                }
            }
        }
    }

    private var content: some View {
        Group {
            if model.revision == nil {
                IndexPlaceholder(state: model.state, hasError: model.connectionError != nil || model.brokerProblem != nil)
                    .padding(16)
            } else if global && model.submittedSearch.isEmpty {
                ContentUnavailableView("Search Disk", systemImage: "magnifyingglass",
                                       description: Text("Enter a name or extension, then press Return."))
            } else if let error = model.browseError {
                if global {
                    ContentUnavailableView {
                        Label("Search Unavailable", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Retry") { model.submitSearch() }.help(error)
                    }
                } else {
                    ContentUnavailableView("List Unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                        .padding(16)
                }
            } else if global && !searchReady {
                ProgressView("Searching…")
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty && (global ? searchReady : model.lastRequest == model.request) {
                emptyState
            } else if model.rows.isEmpty {
                ProgressView().controlSize(.small).accessibilityLabel("Loading Items")
            } else if layout.wrappedValue == .grid {
                grid
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection, sortOrder: sort) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 9) {
                    if global && layout.wrappedValue == .list {
                        FileThumbnail(entry: entry, size: .row, source: model.previewURL(for: entry),
                                      loadsAutomatically: false,
                                      preparedImage: model.searchThumbnails[entry.id])
                            .frame(width: 34, height: 30)
                    } else {
                        Image(systemName: entry.browserSymbol)
                            .font(.system(size: 14))
                            .foregroundStyle(entry.isFolder ? StorageStyle.accent : Color.secondary)
                            .frame(width: 19)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if !folders && layout.wrappedValue != .compact {
                            Text(resultLocation(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, layout.wrappedValue == .compact ? 1 : 3)
                .help(entry.displayPath)
            }
            .width(min: 143, ideal: 334)
            TableColumn("On Disk", value: \.diskBytes) { entry in
                DiskUsageLabel(usage: model.diskUsage(for: entry))
                    .font(.callout)
            }
            .width(min: 99, ideal: 120, max: 152)
            .alignment(.trailing)
            TableColumn("Logical Size", value: \.logical) { entry in
                sizeCell(entry.logical)
            }
            .width(min: 86, ideal: 108, max: 140)
            .alignment(.trailing)
            TableColumn("Modified", value: \.modified) { entry in
                Text(entry.modified, format: .dateTime.day().month(.abbreviated).year().locale(StorageStyle.locale))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 84, ideal: 122, max: 145)
        }
        .controlSize(layout.wrappedValue == .compact ? .small : .regular)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: EntryKey.self) { ids in
            entryActions(model.entries(in: ids))
        } primaryAction: { ids in
            if ids.count == 1, let entry = model.entries(in: ids).first {
                model.activate(entry)
            }
        }
        .onKeyPress(.return) {
            guard let entry = model.selected else { return .ignored }
            model.activate(entry)
            return .handled
        }
        .onKeyPress(.space) { showSelectedPreview() }
        .accessibilityLabel(scopeLabel)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 14
            let columnCount = max(1, Int((geometry.size.width - StorageStyle.inset * 2 + spacing) / (164 + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columnCount)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(model.rows) { entry in
                            gridTile(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, StorageStyle.inset)
                    .padding(.vertical, 14)
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                    let delta: Int
                    switch press.key {
                    case .leftArrow: delta = -1
                    case .rightArrow: delta = 1
                    case .upArrow: delta = -columnCount
                    default: delta = columnCount
                    }
                    return moveGridSelection(by: delta, extending: press.modifiers.contains(.shift), proxy: proxy)
                }
                .onKeyPress("a", phases: .down) { press in
                    guard press.modifiers == .command else { return .ignored }
                    model.selection = Set(model.rows.map(\.id))
                    return .handled
                }
                .onKeyPress(.space) { showSelectedPreview() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(scopeLabel)
    }

    private func gridTile(_ entry: StorageEntry) -> some View {
        let selected = model.selection.contains(entry.id)
        let outline = RoundedRectangle(cornerRadius: 8)
        return Button {
            searchFocused = false
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            selectGridEntry(entry.id, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                FileThumbnail(entry: entry, size: .cover, source: model.previewURL(for: entry),
                              loadsAutomatically: !global, preparedImage: global ? model.searchThumbnails[entry.id] : nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: 114)
                    .padding(5)
                    .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 6))
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                HStack(spacing: 6) {
                    if !folders {
                        Text(resultLocation(for: entry))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    DiskUsageLabel(usage: model.diskUsage(for: entry))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(7)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: outline)
            .overlay { outline.strokeBorder(selected ? Color.accentColor : Color.clear).allowsHitTesting(false) }
            .contentShape(outline)
        }
        .buttonStyle(.plain)
        .focusable(interactions: .edit)
        .focused($gridFocus, equals: entry.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(entry.isFolder ? "Double-click to open" :
                           (model.previewURL(for: entry) == nil ? "Use the context menu to show this file in Finder" : "Press Space to preview"))
        .help(entry.displayPath)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .shift]).isEmpty else { return }
            if let url = model.previewURL(for: entry) { previewURL = url }
            else { model.activate(entry) }
        })
        .contextMenu { entryActions(model.selection.contains(entry.id) ? model.selectedEntries : [entry]) }
        .onKeyPress(.space) {
            showSelectedPreview()
        }
        .onKeyPress(.return) {
            guard model.selection.count <= 1 else { return .ignored }
            if let url = model.previewURL(for: entry) { previewURL = url }
            else { model.activate(entry) }
            return .handled
        }
    }

    private func selectGridEntry(_ key: EntryKey, extending: Bool, toggling: Bool) {
        let anchor = gridAnchor ?? gridFocus
        if extending, let anchor,
           let start = model.rows.firstIndex(where: { $0.id == anchor }),
           let end = model.rows.firstIndex(where: { $0.id == key }) {
            let range = model.rows[min(start, end)...max(start, end)].map(\.id)
            if toggling { model.selection.formUnion(range) }
            else { model.selection = Set(range) }
            gridAnchor = anchor
        } else {
            if toggling, model.selection.contains(key) { model.selection.remove(key) }
            else if toggling { model.selection.insert(key) }
            else { model.selection = [key] }
            gridAnchor = key
        }
        gridFocus = key
    }

    private func moveGridSelection(by delta: Int, extending: Bool, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let current = model.rows.firstIndex(where: { $0.id == (gridFocus ?? model.selected?.id) }) else { return .ignored }
        let next = current + delta
        guard model.rows.indices.contains(next) else { return .handled }
        let id = model.rows[next].id
        proxy.scrollTo(id)
        selectGridEntry(id, extending: extending, toggling: false)
        return .handled
    }

    private func showSelectedPreview() -> KeyPress.Result {
        guard let entry = model.selected, let url = model.previewURL(for: entry) else { return .ignored }
        previewURL = url
        return .handled
    }

    @ViewBuilder
    private func entryActions(_ entries: [StorageEntry]) -> some View {
        if entries.count == 1, let entry = entries.first {
            if entry.isFolder { Button("Open Folder") { model.openFolder(entry.id) } }
            if let url = model.previewURL(for: entry) {
                Button("Preview") { previewURL = url }
            } else if entry.hasThumbnail, let path = entry.parent {
                let parent = EntryKey(tree: entry.id.tree, path: path)
                if model.canOfferPreviewAccess(in: parent) {
                    Button("Allow Previews in This Folder…") { requestPreviews(in: parent) }
                }
            }
            Button("Details") {
                model.selection = [entry.id]
                model.showsDetails = true
            }
            Button("Copy Path") { copyEntryPath(entry) }
        }
        if !entries.isEmpty {
            Button("Show in Finder") { model.reveal(entries.map(\.id)) }
            if !entries.contains(where: { FileDeletion.isProtected($0.id) }) {
                Divider()
                Button("Move to Trash") { moveToTrash(entries) }
                    .disabled(!model.canRemove(entries, by: .trash))
                Button("Delete Permanently…", role: .destructive) { confirmDeletion(entries) }
                    .disabled(!model.canRemove(entries, by: .permanent))
            }
        }
    }

    private func moveToTrash(_ entries: [StorageEntry]) {
        Task { await model.remove(entries, by: .trash) }
    }

    private func confirmDeletion(_ entries: [StorageEntry]) {
        guard model.canRemove(entries, by: .permanent) else { return }
        deletion = DeletionSelection(entries: entries)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.wrappedValue.isEmpty ? "No Indexed Items" : "No Results",
                  systemImage: search.wrappedValue.isEmpty ? "folder" : "magnifyingglass")
        } description: {
            if global { Text("No matches for “\(model.submittedSearch)”.") }
            else if !search.wrappedValue.isEmpty { Text("Try a different name.") }
            else if folders, model.folderInfo == nil { Text("This folder may have been moved or deleted.") }
            else if folders { Text("The index has no accessible items in this folder.") }
        } actions: {
            if global, !model.searchFilters.similar,
               model.globalSearch.trimmingCharacters(in: .whitespacesAndNewlines) == model.submittedSearch {
                Button("Include Similar Names") { model.searchFilters.similar = true }
            }
            else if !search.wrappedValue.isEmpty { Button("Clear Search") { search.wrappedValue = "" } }
            else if folders, model.folder.path != model.folder.tree.root, model.folderInfo == nil {
                Button("Go Back") { model.upOneFolder() }
            }
        }
        .padding(16)
    }

    private func resultLocation(for entry: StorageEntry) -> String {
        let path = parentDisplay(for: entry)
        return global && model.similarNames.contains(entry.id) ? "Similar name · \(path)" : path
    }

    @ViewBuilder
    private var actions: some View {
        if global { searchActions }
        else { browserActions }
    }

    private var searchActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            SearchToolbarLayout {
                searchInput
                HStack(spacing: 8) { searchOptions }
            }
            if !model.submittedSearch.isEmpty,
               model.globalSearch.trimmingCharacters(in: .whitespacesAndNewlines) != model.submittedSearch {
                Text("Results for “\(model.submittedSearch)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .controlSize(.regular)
        .defaultFocus($searchFocused, true)
        .task(id: model.searchFocus) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
    }

    private var searchInput: some View {
        HStack(spacing: 8) {
            searchField
            Button("Search") { model.submitSearch() }
                .buttonStyle(.borderedProminent)
                .disabled(model.globalSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var searchOptions: some View {
        Menu {
            Toggle("Include Similar Names", isOn: $model.searchFilters.similar)
            Picker("Type", selection: $model.searchFilters.kind) {
                Text("All").tag(SearchFilters.Kind.all)
                Text("Files").tag(SearchFilters.Kind.files)
                Text("Folders").tag(SearchFilters.Kind.folders)
            }
        } label: {
            Label(filterLabel, systemImage: "line.3.horizontal.decrease")
        }
        .help("Include separate words and small typos. Turn off similar names to match the exact phrase.")
        if !model.submittedSearch.isEmpty, layout.wrappedValue == .grid { sortMenu }
        viewPicker
    }

    private var filterLabel: String {
        switch model.searchFilters.kind {
        case .files: return "Files Only"
        case .folders: return "Folders Only"
        case .all: return model.searchFilters.similar ? "Filters" : "Exact Phrase"
        }
    }

    private var browserActions: some View {
        HStack(spacing: 8) {
            if folders {
                Button { model.upOneFolder() } label: {
                    Label("Parent Folder", systemImage: "chevron.up").labelStyle(.iconOnly)
                }
                .disabled(model.folder.path == model.folder.tree.root)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Parent Folder")
                breadcrumb
                    .frame(maxWidth: 320, alignment: .leading)
                Spacer(minLength: 0)
            }
            searchField
            if !folders { Spacer(minLength: 0) }
            if layout.wrappedValue == .grid || (!folders && !global) { sortMenu }
            viewPicker
        }
        .controlSize(.small)
        .font(.callout)
    }

    private var viewPicker: some View {
        Picker("View", selection: layout) {
            ForEach(BrowserLayout.allCases) { option in
                Label(option.title, systemImage: option.symbol).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Change View")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(global ? "Name or extension" : (folders ? "Search this folder" : "Search by name"), text: search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if global { model.submitSearch() } }
                .accessibilityLabel(global ? "Search files and folders" : (folders ? "Search this folder" : "Search files by name"))
            if !search.wrappedValue.isEmpty {
                Button {
                    if global { model.clearSearch() }
                    else { search.wrappedValue = "" }
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
        }
        .font(global ? .body : .callout)
        .padding(.horizontal, global ? 11 : 8)
        .padding(.vertical, global ? 9 : 5)
        .frame(minWidth: 114, idealWidth: folders ? 190 : 350, maxWidth: global ? .infinity : folders ? 235 : 520)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searchFocused ? Color.accentColor : .secondary.opacity(0.18),
                              lineWidth: searchFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { model.request.sort }, set: { field in
                sort.wrappedValue = [field.comparator(field == .name ? .forward : .reverse)]
            })) {
                ForEach(EntrySort.allCases, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            }
            Divider()
            Toggle("Descending", isOn: Binding(get: { !model.request.ascending }, set: { descending in
                sort.wrappedValue = [model.request.sort.comparator(descending ? .reverse : .forward)]
            }))
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
        .help("Sort by \(model.request.sort.title)")
    }

    private var breadcrumb: some View {
        let trail = model.folderTrail
        return HStack(spacing: 6) {
            Menu {
                Button(model.volumeName) { model.openFolder(EntryKey(tree: .data, path: VolumeTree.data.root)) }
                if !model.isFixture {
                    Button(VolumeTree.systemDisplayName) { model.openFolder(EntryKey(tree: .system, path: "/")) }
                }
                if trail.count > 2 {
                    Divider()
                    ForEach(trail.dropFirst().dropLast(), id: \.1) { name, key in
                        Button(name) { model.openFolder(key) }
                    }
                }
            } label: {
                Label(trail.first?.0 ?? "Disk", systemImage: "internaldrive")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 155, alignment: .leading)
            .accessibilityLabel("Location and Disks")
            if let last = trail.last, trail.count > 1 {
                Image(systemName: trail.count > 2 ? "ellipsis" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(last.0)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .help(SpaceTrailPaths.displayPath(last.1.path))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        let entries = model.selectedEntries
        return HStack(spacing: 8) {
            if !entries.isEmpty {
                if entries.count > 1 {
                    Text("\(StorageStyle.count(entries.count)) selected")
                        .foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize()
                }
                Button {
                    model.reveal(model.selectedEntries.map(\.id))
                } label: {
                    Label("Show in Finder", systemImage: "arrow.up.forward.app")
                }
                .keyboardShortcut("r", modifiers: .command)
                if let entry = model.selected {
                    if let url = model.previewURL(for: entry) {
                        Button { previewURL = url } label: {
                            Label("Preview", systemImage: "eye").labelStyle(.iconOnly)
                        }
                        .help("Preview (Space)")
                    }
                    HStack(spacing: 4) {
                        Text("On Disk").foregroundStyle(.secondary)
                        DiskUsageLabel(usage: model.diskUsage(for: entry))
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text(pageLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.inspectedEntry != nil {
                Button { model.showsDetails.toggle() } label: {
                    Label(model.showsDetails ? "Hide Details" : "Details", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .help(model.showsDetails ? "Hide Details" : "Show exact sizes and details")
            }
            Spacer()
            if entries.contains(where: { FileDeletion.isProtected($0.id) }) {
                Label(entries.count == 1 ? "Protected Location" : "Selection Includes Protected Items", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("SpaceTrail can remove personal files in the accessible folders of your account.")
            } else if !entries.isEmpty {
                Button { moveToTrash(model.selectedEntries) } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .fixedSize()
                .disabled(!model.canRemove(entries, by: .trash) || searchFocused)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Move selected files to Trash (⌘⌫)")
                let allowed = model.canRemove(entries, by: .permanent)
                Button(role: .destructive) { confirmDeletion(model.selectedEntries) } label: {
                    Text("Delete…")
                }
                .fixedSize()
                .accessibilityLabel("Delete Permanently")
                .disabled(!allowed || searchFocused)
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .help(allowed ? "Delete permanently (⌥⌘⌫)" : "Select files or links in an accessible location.")
            }
            if model.page > 0 || model.hasMore {
                Button { model.page -= 1; model.selection.removeAll() } label: {
                    Label("Previous Page", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .disabled(model.page == 0)
                .help("Previous Page")
                Button { model.page += 1; model.selection.removeAll() } label: {
                    Label("Next Page", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .disabled(!model.hasMore || (global ? !searchReady : model.lastRequest != model.request))
                .help("Next Page")
            }
        }
        .controlSize(.small)
        .font(.caption)
        .frame(minHeight: 22)
    }

    private var pageLabel: String {
        if model.page == 0 && !model.hasMore {
            let count = model.rows.count
            return count == 1 ? "1 item" : "\(StorageStyle.count(count)) items"
        }
        let first = model.page * model.request.limit + 1
        let last = first + model.rows.count - 1
        return "Items \(StorageStyle.count(first))–\(StorageStyle.count(last))"
    }

    private func sizeCell(_ bytes: Int64) -> some View {
        Text(StorageStyle.size(bytes))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1)
            .help(StorageStyle.exactSize(bytes))
            .accessibilityLabel(StorageStyle.exactSize(bytes))
    }

    private func parentDisplay(for entry: StorageEntry) -> String {
        StorageStyle.location(entry.parent ?? entry.id.path)
    }
}

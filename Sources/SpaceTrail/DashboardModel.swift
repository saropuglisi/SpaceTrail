import AppKit
import Observation
import ServiceManagement
import SpaceTrailCore
import SwiftUI

enum DashboardSection: String, Identifiable, CaseIterable {
    case files = "File"
    case folders = "Cartelle"
    case search = "Cerca"
    case map = "Mappa"
    case space = "Spazio"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .files: return "doc.on.doc"
        case .folders: return "folder"
        case .search: return "magnifyingglass"
        case .map: return "square.split.2x2"
        case .space: return "internaldrive"
        }
    }
}

struct PageRequest: Equatable {
    let scope: EntryScope
    let sort: EntrySort
    let ascending: Bool
    let search: String
    let page: Int
    let limit: Int
    let filters: SearchFilters
    let submission: Int
    var revision: String?

    var withoutRevision: Self {
        var request = self
        request.revision = nil
        return request
    }
}

struct ThumbnailAccess: Equatable {
    let disk: DiskAccess?
    let selectedFolders: Int
}

enum RemovalMethod: Sendable {
    case trash, permanent

    var progress: String {
        self == .trash ? "Spostamento nel Cestino…" : "Eliminazione in corso…"
    }

    var failureTitle: String {
        self == .trash ? "Spostamento non riuscito" : "File non eliminati"
    }
}

enum RemovalSource {
    case browser, map(EntryKey)
}

struct DeletionReport: Sendable {
    struct Failure: Identifiable, Sendable {
        let entry: StorageEntry
        let reason: String

        var id: EntryKey { entry.id }
    }

    let method: RemovalMethod
    var removed: [StorageEntry] = []
    var missing: [StorageEntry] = []
    var failures: [Failure] = []
    var space: DeletionSpace?

    var hasItemsInTrash: Bool { method == .trash && !removed.isEmpty }

    var summary: String {
        var parts: [String] = []
        if hasItemsInTrash {
            parts.append(removed.first?.isFolder == true ? "Cartella nel Cestino" : "\(removed.count.formatted()) file nel Cestino")
        }
        else if !removed.isEmpty { parts.append(removed.count == 1 ? "1 file eliminato" : "\(removed.count.formatted()) file eliminati") }
        if !missing.isEmpty { parts.append(missing.first?.isFolder == true ? "Cartella già rimossa" : "\(missing.count) già rimossi") }
        if !failures.isEmpty {
            let count = failures.count.formatted()
            switch method {
            case .trash:
                parts.append(failures.first?.entry.isFolder == true ? "Cartella non spostata" :
                    failures.count == 1 ? "1 file non spostato" : "\(count) file non spostati")
            case .permanent: parts.append(failures.count == 1 ? "1 file non eliminato" : "\(count) file non eliminati")
            }
        }
        if let space { parts.append(space.message) }
        return parts.joined(separator: "  ·  ")
    }
}

@MainActor
@Observable
final class DashboardModel {
    private struct RecentRemoval: Equatable, Sendable {
        let inode: Int64
        let until: ContinuousClock.Instant
        let inTrash: Bool
        let isFolder: Bool
    }
    nonisolated static let pageSize = 150
    nonisolated static let searchPageSize = 48

    private var navigation = NavigationHistory()
    private(set) var folder = EntryKey(tree: .data, path: VolumeTree.data.root)
    private(set) var mapFolder = EntryKey(tree: .data, path: VolumeTree.data.root)
    var fileSearch = ""
    var globalSearch = ""
    var searchFilters = SearchFilters()
    private(set) var submittedSearch = ""
    private var submittedFilters = SearchFilters()
    private var searchSubmission = 0
    private(set) var similarNames: Set<EntryKey> = []
    private(set) var searchThumbnails: [EntryKey: CGImage] = [:]
    private(set) var preparedThumbnailSize: FileThumbnail.Size?
    private(set) var preparedThumbnailScale: CGFloat = 1
    private(set) var preparedThumbnailAccess: ThumbnailAccess?
    private var previewGrants: [EntryKey: PreviewFolderGrant] = [:]
    var searchFocus = 0
    var globalOrder = [KeyPathComparator(\StorageEntry.name)]
    var folderSearch = ""
    var fileOrder = [KeyPathComparator(\StorageEntry.diskBytes, order: .reverse)]
    var folderOrder = [KeyPathComparator(\StorageEntry.diskBytes, order: .reverse)]
    var page = 0
    var rows: [StorageEntry] = []
    var folderInfo: StorageEntry?
    var hasMore = false
    var selection: Set<EntryKey> = []
    private(set) var removalInProgress: RemovalMethod?
    var deletionReport: DeletionReport?
    var deletionNotice: DeletionSpace?
    var state: BrokerState?
    var diskAccess = DiskAccess.read(in: SpaceTrailPaths.support)
    private(set) var foregroundAccess: DiskAccess?
    var thumbnailAccess: ThumbnailAccess {
        ThumbnailAccess(disk: foregroundAccess, selectedFolders: previewGrants.count)
    }
    var accessSetupError: String?
    var brokerProblem: String?
    var showsDetails = false
    var overview: Overview?
    private(set) var overviewIncludesDetails = false
    var revision: String?
    var connectionError: String?
    var browseError: String?
    var serviceError: String?
    var lastRequest: PageRequest?
    var serviceStatus: SMAppService.Status = .notRegistered
    private(set) var wantsBackground = UserDefaults.standard.object(forKey: "backgroundUpdates") as? Bool ?? true

    private var liveVolumeSpace: VolumeSpace?
    @ObservationIgnored private let reader = IndexReader()
    @ObservationIgnored private let service = SMAppService.agent(plistName: SpaceTrailPaths.agentPlist)
    @ObservationIgnored private let brokerBuild = Bundle(
        url: Bundle.main.bundleURL.appendingPathComponent(SpaceTrailPaths.agentBundle)
    )?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    @ObservationIgnored private var checkedBackgroundBuild = UserDefaults.standard.string(forKey: "checkedBackgroundBuild")
    @ObservationIgnored private var sessionProcess: Process?
    @ObservationIgnored private var triedRegistration = false
    @ObservationIgnored private(set) var backgroundRegistrationTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundGraceUntil = ContinuousClock.Instant.now
    @ObservationIgnored private var nextSessionAttempt = ContinuousClock.Instant.now
    @ObservationIgnored private var sessionRetryDelay: Double = 2
    @ObservationIgnored private var reviewPending = false
    @ObservationIgnored private var nextAccessCheck = ContinuousClock.Instant.now
    private var recentlyRemoved: [EntryKey: RecentRemoval] = [:]

    var activeSection: DashboardSection { navigation.current.section }
    var indexAccess: DiskAccess? { diskAccess == .limited ? .limited : state?.effectiveAccess ?? foregroundAccess }

    init() {
        foregroundAccess = diskAccess?.effective
    }

    var isFixture: Bool { SpaceTrailPaths.fixtureRoot != nil }
    var backgroundRunning: Bool {
        guard let state, state.phase != .failed else { return false }
        // Versions that predate this field can still provide a live, registered agent.
        return state.background ?? (serviceStatus == .enabled && sessionProcess?.processIdentifier != state.pid)
    }
    var needsBackgroundApproval: Bool { wantsBackground && serviceStatus == .requiresApproval }
    var brokerStatus: String {
        if backgroundRunning { return "Aggiornamento automatico" }
        if state?.phase == .failed { return "Aggiornamenti in pausa" }
        if state != nil { return "Aggiorna mentre l’app è aperta" }
        return "Avvio dell’aggiornamento"
    }
    var volumeSpace: VolumeSpace? {
        liveVolumeSpace ?? overview?.sample.map { VolumeSpace(capacity: $0.capacity, available: $0.available) }
    }
    var selected: StorageEntry? {
        guard selection.count == 1, let key = selection.first else { return nil }
        return rows.first { $0.id == key }
    }
    var selectedEntries: [StorageEntry] { entries(in: selection) }
    var inspectedEntry: StorageEntry? {
        if !selection.isEmpty { return selected }
        return activeSection == .folders ? folderInfo : nil
    }

    func entries(in keys: Set<EntryKey>) -> [StorageEntry] {
        rows.filter { keys.contains($0.id) }
    }

    var request: PageRequest {
        let scope: EntryScope
        let search: String
        let sort: KeyPathComparator<StorageEntry>?
        switch activeSection {
        case .folders: (scope, search, sort) = (.children(folder), folderSearch, folderOrder.first)
        case .search: (scope, search, sort) = (.search, submittedSearch, globalOrder.first)
        case .files, .map, .space: (scope, search, sort) = (.files, fileSearch, fileOrder.first)
        }
        let field: EntrySort
        switch sort?.keyPath {
        case \StorageEntry.name: field = .name
        case \StorageEntry.diskBytes: field = .allocated
        case \StorageEntry.modified: field = .modified
        default: field = .logical
        }
        return PageRequest(scope: scope, sort: field,
                           ascending: sort?.order == .forward, search: search,
                           page: page, limit: scope == .search ? Self.searchPageSize : Self.pageSize,
                           filters: scope == .search ? submittedFilters : SearchFilters(),
                           submission: scope == .search ? searchSubmission : 0, revision: revision)
    }

    var folderTitle: String {
        if folder.path == folder.tree.root { return folder.tree == .data ? volumeName : "Sistema macOS" }
        return String(folder.path.split(separator: "/").last ?? "/")
    }

    var volumeName: String {
        if let fixture = SpaceTrailPaths.fixtureRoot {
            return URL(fileURLWithPath: fixture).lastPathComponent
        }
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? "Disco di avvio"
    }

    var folderTrail: [(String, EntryKey)] { trail(to: folder) }

    func trail(to key: EntryKey) -> [(String, EntryKey)] {
        let root = key.tree.root
        let rootName = key.tree == .data ? volumeName : "Sistema macOS"
        var result = [(rootName, EntryKey(tree: key.tree, path: root))]
        let subpath = key.path.dropFirst(root.count)
        var path = root
        for component in subpath.split(separator: "/") {
            path += (path == "/" ? "" : "/") + component
            result.append((String(component), EntryKey(tree: key.tree, path: path)))
        }
        return result
    }

    func watch() async {
        refreshService()
        if !triedRegistration {
            triedRegistration = true
            registerBackgroundIfNeeded()
        }
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func poll() async {
        if ContinuousClock.now >= nextAccessCheck {
            nextAccessCheck = .now + .seconds(5)
            let effective = diskAccess?.effective
            if foregroundAccess != effective { foregroundAccess = effective }
        }
        refreshVolumeSpace()
        let hadBackground = backgroundRunning
        refreshService()
        let currentState = BrokerState.read(in: reader.support)
        if state != currentState { state = currentState }
        if hadBackground, !backgroundRunning { backgroundGraceUntil = .now + .seconds(26) }
        refreshBackgroundRegistrationIfNeeded()
        if let currentState, currentState.phase != .failed {
            brokerProblem = nil
            if currentState.phase == .monitoring || currentState.phase == .checking {
                sessionRetryDelay = 2
                if reviewPending {
                    reviewPending = false
                    post(SpaceTrailPaths.reviewNotification)
                }
            }
        } else {
            brokerProblem = currentState?.detail
            startSessionIfNeeded()
        }
        if revision == nil, let phase = currentState?.phase,
           [.scanning, .finishing].contains(phase) {
            connectionError = nil
            return
        }
        do {
            let includeDetails = activeSection == .space
            let previous = overviewIncludesDetails == includeDetails ? revision : nil
            let reader = self.reader
            let read = Task.detached(priority: .utility) {
                try reader.dashboard(since: previous, includeDetails: includeDetails)
            }
            let result = try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
            guard !Task.isCancelled else { return }
            if let updated = result.overview {
                overview = updated
                overviewIncludesDetails = includeDetails
                if revision != result.revision { revision = result.revision }
            }
            if result.revision != nil || currentState != nil { connectionError = nil }
        } catch {
            if !Task.isCancelled, currentState?.phase != .preparing { connectionError = error.localizedDescription }
        }
    }

    func load(_ request: PageRequest, thumbnailSize: FileThumbnail.Size? = nil, thumbnailScale: CGFloat = 1) async {
        guard request.revision != nil else { return }
        if request.scope == .search {
            guard !request.search.isEmpty else { return }
        } else if !request.search.isEmpty, request.search != lastRequest?.search {
            try? await Task.sleep(for: .milliseconds(170))
        }
        guard !Task.isCancelled, isCurrent(request) else { return }
        let reader = self.reader
        let access = foregroundAccess
        let thumbnailAccess = self.thumbnailAccess
        let pendingMoves = pendingTrashMoves
        do {
            let query = Task.detached(priority: .userInitiated) {
                let page = try reader.page(scope: request.scope, sort: request.sort,
                                           ascending: request.ascending, search: request.search,
                                           offset: request.page * request.limit, limit: request.limit, filters: request.filters)
                var folder: StorageEntry?
                if case .children(let key) = request.scope { folder = try reader.entry(key) }
                let restored = Self.restoredEntries(in: page.rows, pending: pendingMoves, access: access)
                return (page, folder, restored)
            }
            let result = try await withTaskCancellationHandler {
                try await query.value
            } onCancel: {
                query.cancel()
            }
            guard !Task.isCancelled, isCurrent(request) else { return }
            if result.0.rows.isEmpty && request.page > 0 {
                page -= 1
                return
            }
            clearRemovalMarkers(restored: result.2, pending: pendingMoves)
            let visibleRows = result.0.rows.filter { !hidesRemovedEntry($0) }
            if request.scope == .search &&
                (lastRequest?.withoutRevision != request.withoutRevision || rows != visibleRows ||
                 preparedThumbnailSize != thumbnailSize || preparedThumbnailScale != thumbnailScale ||
                 preparedThumbnailAccess != thumbnailAccess) {
                var thumbnails: [EntryKey: CGImage] = [:]
                if let thumbnailSize {
                    let eligible = visibleRows.compactMap { entry -> (StorageEntry, URL)? in
                        guard entry.hasThumbnail, let url = previewURL(for: entry) else { return nil }
                        return (entry, url)
                    }
                    thumbnails = await ThumbnailResources.shared.prepare(eligible, size: thumbnailSize, scale: thumbnailScale)
                }
                guard !Task.isCancelled, isCurrent(request) else { return }
                searchThumbnails = thumbnails
                preparedThumbnailSize = thumbnailSize
                preparedThumbnailScale = thumbnailScale
                preparedThumbnailAccess = thumbnailAccess
            }
            let currentRows = visibleRows.filter { !hidesRemovedEntry($0) }
            if rows != currentRows { rows = currentRows }
            if hasMore != result.0.hasMore { hasMore = result.0.hasMore }
            if similarNames != result.0.similarNames { similarNames = result.0.similarNames }
            if folderInfo != result.1 { folderInfo = result.1 }
            browseError = nil
            lastRequest = request
            selection.formIntersection(rows.lazy.map(\.id))
        } catch {
            if !Task.isCancelled, isCurrent(request) { browseError = error.localizedDescription }
        }
    }

    private func isCurrent(_ request: PageRequest) -> Bool {
        switch request.scope {
        case .search: return activeSection == .search && self.request.withoutRevision == request.withoutRevision
        case .files: return activeSection == .files && self.request == request
        case .children: return activeSection == .folders && self.request == request
        }
    }

    func mapPage(in folder: EntryKey) async throws -> MapPage {
        let reader = self.reader
        let pendingMoves = pendingTrashMoves
        let access = foregroundAccess
        let query = Task.detached(priority: .userInitiated) {
            let page = try reader.mapPage(in: folder, limit: 32)
            let entries = pendingMoves.isEmpty ? [] : page.contents.rows + page.previews.values.flatMap { $0 }
            return (page, Self.restoredEntries(in: entries, pending: pendingMoves, access: access))
        }
        let (page, restored) = try await withTaskCancellationHandler {
            try await query.value
        } onCancel: {
            query.cancel()
        }
        try Task.checkCancellation()
        clearRemovalMarkers(restored: restored, pending: pendingMoves)
        return page
    }

    func hidesRemovedEntry(_ entry: StorageEntry) -> Bool {
        let now = ContinuousClock.now
        if let marker = recentlyRemoved[entry.id], marker.until > now, marker.inode == entry.inode { return true }
        guard recentlyRemoved.values.contains(where: { $0.isFolder && $0.until > now }) else { return false }
        var parent = entry.parent
        while let path = parent {
            let key = EntryKey(tree: entry.id.tree, path: path)
            if let marker = recentlyRemoved[key], marker.isFolder, marker.until > now { return true }
            guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { break }
            parent = String(path[..<slash])
        }
        return false
    }

    private var pendingTrashMoves: [EntryKey: RecentRemoval] {
        recentlyRemoved.filter { $0.value.inTrash && $0.value.until > .now }
    }

    private nonisolated static func restoredEntries(in entries: [StorageEntry], pending: [EntryKey: RecentRemoval],
                                                     access: DiskAccess?) -> [EntryKey] {
        guard let access, !pending.isEmpty else { return [] }
        return entries.compactMap { entry in
            guard let marker = pending[entry.id], marker.inode != entry.inode ||
                FileDeletion.isCurrent(entry, access: access) else { return nil }
            return entry.id
        }
    }

    private func clearRemovalMarkers(restored: [EntryKey], pending: [EntryKey: RecentRemoval]) {
        var retained = recentlyRemoved.filter { $0.value.until > .now }
        for key in restored where retained[key] == pending[key] { retained.removeValue(forKey: key) }
        if retained != recentlyRemoved { recentlyRemoved = retained }
    }

    func resetPage(clear: Bool = false) {
        page = 0
        selection.removeAll()
        deletionReport = nil
        browseError = nil
        if clear {
            rows = []
            folderInfo = nil
            hasMore = false
            lastRequest = nil
            similarNames = []
            searchThumbnails = [:]
            preparedThumbnailSize = nil
        }
    }

    func submitSearch() {
        submittedSearch = globalSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedFilters = searchFilters
        searchSubmission += 1
        resetPage(clear: true)
    }

    func applySearchFilters() {
        guard !submittedSearch.isEmpty, searchFilters != submittedFilters,
              globalSearch.trimmingCharacters(in: .whitespacesAndNewlines) == submittedSearch else { return }
        submitSearch()
    }

    func clearSearch() {
        globalSearch = ""
        submittedSearch = ""
        searchSubmission += 1
        resetPage(clear: true)
    }

    func showSearch() {
        navigate(to: .search)
        searchFocus += 1
    }

    func selectSection(_ section: DashboardSection) {
        switch section {
        case .files: navigate(to: .files)
        case .folders: navigate(to: .folders(folder))
        case .search: navigate(to: .search)
        case .map: navigate(to: .map(mapFolder))
        case .space: navigate(to: .space)
        }
    }

    func openFolder(_ key: EntryKey) {
        if !folderSearch.isEmpty { folderSearch = "" }
        navigate(to: .folders(key))
    }

    func openMap(_ key: EntryKey) { navigate(to: .map(key)) }

    func canStep(_ direction: HistoryDirection) -> Bool { navigation.canStep(direction) }

    @discardableResult
    func step(_ direction: HistoryDirection) -> Bool {
        guard let location = navigation.step(direction) else { return false }
        display(location)
        return true
    }

    private func navigate(to location: DashboardLocation) {
        if navigation.visit(location) { display(location) }
    }

    private func display(_ location: DashboardLocation) {
        switch location {
        case .folders(let key) where key != folder:
            folder = key
            folderSearch = ""
        case .map(let key): mapFolder = key
        default: break
        }
        resetPage(clear: true)
    }

    func upOneFolder() {
        guard folder.path != folder.tree.root else { return }
        let parent = URL(fileURLWithPath: folder.path).deletingLastPathComponent().path
        openFolder(EntryKey(tree: folder.tree, path: parent))
    }

    func activate(_ entry: StorageEntry) {
        if entry.isFolder { openFolder(entry.id) }
        else { reveal(entry.id) }
    }

    func reveal(_ key: EntryKey) {
        reveal([key])
    }

    func reveal(_ keys: [EntryKey]) {
        NSWorkspace.shared.activateFileViewerSelecting(keys.map { URL(fileURLWithPath: $0.path) })
    }

    func openFolderInFinder(_ key: EntryKey) {
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SpaceTrailPaths.displayPath(key.path)) {
            reveal(key)
        }
    }

    func canRemove(_ entries: [StorageEntry], by method: RemovalMethod, from source: RemovalSource = .browser) -> Bool {
        guard let access = foregroundAccess, !entries.isEmpty, removalInProgress == nil,
              !entries.contains(where: hidesRemovedEntry) else { return false }
        switch source {
        case .browser:
            guard activeSection != .map, lastRequest?.withoutRevision == request.withoutRevision,
                  !entries.contains(where: \.isFolder) else { return false }
        case .map(let folder):
            guard activeSection == .map, folder == mapFolder, method == .trash,
                  entries.count == 1, let entry = entries.first, entry.id.tree == folder.tree,
                  entry.id != folder, entry.id.path.hasPrefix(folder.path == "/" ? "/" : folder.path + "/") else { return false }
        }
        switch method {
        case .trash: return entries.allSatisfy { FileDeletion.canMoveToTrash($0, access: access) }
        case .permanent: return entries.allSatisfy { FileDeletion.canRemove($0, access: access) }
        }
    }

    func remove(_ entries: [StorageEntry], by method: RemovalMethod, from source: RemovalSource = .browser) async {
        guard canRemove(entries, by: method, from: source), let access = foregroundAccess else { return }
        removalInProgress = method
        deletionReport = nil
        deletionNotice = nil
        let result = await Task.detached(priority: .userInitiated) {
            let before = method == .permanent ? VolumeSpace.read() : nil
            var report = DeletionReport(method: method)
            for entry in entries {
                do {
                    switch method {
                    case .trash: try FileDeletion.moveToTrash(entry, access: access)
                    case .permanent: try FileDeletion.remove(entry, access: access)
                    }
                    report.removed.append(entry)
                } catch FileDeletion.Failure.missing {
                    report.missing.append(entry)
                } catch {
                    report.failures.append(.init(entry: entry, reason: error.localizedDescription))
                }
            }
            return (report, before)
        }.value
        var report = result.0
        let missing = report.removed + report.missing
        for entry in missing {
            recentlyRemoved[entry.id] = RecentRemoval(inode: entry.inode, until: .now + .seconds(30),
                                                     inTrash: method == .trash, isFolder: entry.isFolder)
        }
        rows.removeAll { hidesRemovedEntry($0) }
        selection.formIntersection(rows.lazy.map(\.id))
        if method == .permanent, !report.removed.isEmpty {
            let space = DeletionSpace(bytes: await measureFreedSpace(since: result.1))
            report.space = space
            deletionNotice = space
        } else {
            refreshVolumeSpace()
        }
        deletionReport = report
        removalInProgress = nil
        if method == .trash { AccessibilityNotification.Announcement(report.summary).post() }
    }

    @discardableResult
    private func refreshVolumeSpace() -> VolumeSpace? {
        guard let space = VolumeSpace.read() else { return nil }
        if liveVolumeSpace != space { liveVolumeSpace = space }
        return space
    }

    private func measureFreedSpace(since before: VolumeSpace?) async -> Int64? {
        var latest = refreshVolumeSpace()
        guard let before else { return nil }

        // Allow the volume to publish the reclaimed blocks after the unlink completes.
        for delay in [120, 240, 480] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard let reading = refreshVolumeSpace() else { continue }
            let settled = reading == latest
            latest = reading
            if settled, let bytes = reading.increase(since: before), bytes > 0 { return bytes }
        }
        return latest?.increase(since: before)
    }

    func refreshService() {
        guard !isFixture else { return }
        let status = service.status
        if status != serviceStatus {
            serviceStatus = status
            if status == .enabled { backgroundGraceUntil = .now + .seconds(26) }
        }
    }

    func setBackground(_ enabled: Bool) {
        guard !isFixture, diskAccess != nil else { return }
        backgroundRegistrationTask?.cancel()
        backgroundRegistrationTask = nil
        wantsBackground = enabled
        UserDefaults.standard.set(enabled, forKey: "backgroundUpdates")
        refreshService()
        if enabled {
            registerBackgroundIfNeeded()
            return
        }
        do {
            if serviceStatus == .enabled || serviceStatus == .requiresApproval {
                try service.unregister()
            }
            refreshService()
            serviceError = nil
        } catch {
            refreshService()
            wantsBackground = true
            UserDefaults.standard.set(true, forKey: "backgroundUpdates")
            serviceError = error.localizedDescription
        }
    }

    func openBackgroundSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerBackgroundIfNeeded() {
        guard !isFixture, diskAccess != nil, wantsBackground,
              serviceStatus == .notRegistered || serviceStatus == .notFound else { return }
        do {
            try service.register()
            serviceError = nil
        } catch {
            serviceError = error.localizedDescription
        }
        refreshService()
        if needsBackgroundApproval { serviceError = nil }
    }

    private func refreshBackgroundRegistrationIfNeeded() {
        guard !isFixture, wantsBackground, serviceStatus == .enabled,
              let build = brokerBuild, build != checkedBackgroundBuild else { return }
        if backgroundRunning, state?.build == build {
            rememberBackgroundBuild(build)
            return
        }
        guard backgroundRunning || ContinuousClock.Instant.now >= backgroundGraceUntil else { return }
        // An updated bundle can leave Service Management pointing at an old helper.
        // Refresh this approved registration at most once for the installed build.
        rememberBackgroundBuild(build)
        do {
            try service.unregister()
            refreshService()
            // Let macOS retire the previous job and its launch constraints before
            // registering the replacement. The local helper covers this interval.
            backgroundRegistrationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(26)) }
                catch { return }
                guard let self else { return }
                self.refreshService()
                self.registerBackgroundIfNeeded()
                self.backgroundRegistrationTask = nil
            }
        } catch {
            refreshService()
            serviceError = error.localizedDescription
        }
    }

    private func rememberBackgroundBuild(_ build: String) {
        checkedBackgroundBuild = build
        UserDefaults.standard.set(build, forKey: "checkedBackgroundBuild")
    }

    private func startSessionIfNeeded(force: Bool = false) {
        guard diskAccess != nil, sessionProcess?.isRunning != true else { return }
        let now = ContinuousClock.Instant.now
        if !force {
            guard now >= nextSessionAttempt, serviceStatus != .enabled || now >= backgroundGraceUntil else { return }
        }
        if let state = BrokerState.read(in: reader.support), state.phase != .failed { return }
        nextSessionAttempt = now + .seconds(sessionRetryDelay)
        sessionRetryDelay = min(60, sessionRetryDelay * 2)

        let embedded = Bundle.main.bundleURL.appendingPathComponent(SpaceTrailPaths.agentBundle)
            .appendingPathComponent(SpaceTrailPaths.agentExecutable)
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SpaceTrailBroker")
        let candidate = FileManager.default.isExecutableFile(atPath: embedded.path) ? embedded : sibling
        guard let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) else {
            connectionError = "Il broker non è presente nel pacchetto di SpaceTrail."
            return
        }
        do {
            let process = Process()
            process.executableURL = candidate
            process.arguments = ["--session-parent", String(getpid())]
            try process.run()
            sessionProcess = process
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    @discardableResult
    func configureAccess(_ access: DiskAccess) -> Bool {
        do {
            try access.write(in: reader.support)
        } catch {
            accessSetupError = error.localizedDescription
            return false
        }
        let wasConfigured = diskAccess != nil
        diskAccess = access
        foregroundAccess = access.effective
        accessSetupError = nil
        guard wasConfigured else { return true }

        nextSessionAttempt = .now
        post(SpaceTrailPaths.accessNotification)
        return true
    }

    func previewURL(for entry: StorageEntry) -> URL? {
        guard let indexedURL = entry.previewURL, entry.id.protectedAppDataScope == nil else { return nil }
        if foregroundAccess?.includes(entry.id) == true { return indexedURL }
        guard let parent = entry.parent, let grant = previewGrants[EntryKey(tree: entry.id.tree, path: parent)] else { return nil }
        return grant.url.appendingPathComponent(indexedURL.lastPathComponent, isDirectory: false)
    }

    func canOfferPreviewAccess(in folder: EntryKey) -> Bool {
        guard let home = SpaceTrailPaths.personalFolder, folder.tree == home.tree,
              folder.path.hasPrefix(home.path + "/"), foregroundAccess?.includes(folder) == false,
              previewGrants[folder] == nil else { return false }
        let root = folder.path.dropFirst(home.path.count + 1).split(separator: "/").first
        return root.map { ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].contains($0) } == true
    }

    func choosePreviewFolder(_ folder: EntryKey) async -> String? {
        guard canOfferPreviewAccess(in: folder) else { return nil }
        let expected = URL(fileURLWithPath: SpaceTrailPaths.displayPath(folder.path), isDirectory: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = false
        panel.canCreateDirectories = false
        panel.directoryURL = expected
        panel.prompt = "Consenti anteprime"
        panel.message = "Seleziona «\(expected.lastPathComponent)» per vedere le anteprime dei file al suo interno."
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return nil }
        guard SpaceTrailPaths.displayPath(url.standardizedFileURL.path) == expected.standardizedFileURL.path else {
            return "Seleziona «\(expected.lastPathComponent)» per vedere le sue anteprime."
        }
        previewGrants[folder] = PreviewFolderGrant(url: url)
        return nil
    }

    func diskUsage(for entry: StorageEntry, includeSavedMeasurement: Bool = false) -> DiskUsage {
        if !entry.isFolder { return .allocated(entry.allocated) }
        let protected = indexAccess?.includes(entry.id) == false
        if protected && !includeSavedMeasurement { return .protected }
        if let estimate = entry.footprint {
            if estimate.incomplete && estimate.bytes == 0 && entry.allocated > 0 {
                if protected { return .protected }
                return estimate.scannedFiles < entry.files ? .verifying : .unavailable
            }
            return .estimate(estimate, files: entry.files)
        }
        if protected { return .protected }
        return brokerProblem == nil ? .verifying : .unavailable
    }

    private func post(_ notification: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: reader.support.path, userInfo: nil, deliverImmediately: true
        )
    }

    func requestCheck() {
        refreshService()
        registerBackgroundIfNeeded()
        reviewPending = true
        startSessionIfNeeded(force: true)
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealBroker() {
        let broker = Bundle.main.bundleURL.appendingPathComponent(SpaceTrailPaths.agentBundle, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([broker])
    }
}

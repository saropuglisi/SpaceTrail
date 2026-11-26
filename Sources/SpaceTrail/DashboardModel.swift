import AppKit
import Observation
import ServiceManagement
import SpaceTrailCore
import SwiftUI

enum DashboardSection: String, Identifiable, CaseIterable {
    case files = "Files"
    case folders = "Folders"
    case search = "Search"
    case map = "Map"
    case space = "Storage"

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

    var hasQuery: Bool { !search.isEmpty || filters.format != .all }

    var withoutRevision: Self {
        var request = self
        request.revision = nil
        return request
    }
}

struct ThumbnailAccess: Equatable {
    let disk: DiskAccess?
    let folderRevision: Int
}

enum RemovalMethod: Sendable {
    case trash, permanent

    var progress: String {
        self == .trash ? "Moving to Trash…" : "Deleting…"
    }

    var failureTitle: String {
        self == .trash ? "Could Not Move to Trash" : "Could Not Delete Files"
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
            let count = removed.count
            let moved = count == 1 ? "1 file moved to Trash" : "\(StorageStyle.count(count)) files moved to Trash"
            parts.append(removed.first?.isFolder == true ? "Folder moved to Trash" : moved)
        }
        else if !removed.isEmpty { parts.append(removed.count == 1 ? "1 file deleted" : "\(StorageStyle.count(removed.count)) files deleted") }
        if !missing.isEmpty { parts.append(missing.first?.isFolder == true ? "Folder already removed" : "\(StorageStyle.count(missing.count)) already removed") }
        if !failures.isEmpty {
            let count = StorageStyle.count(failures.count)
            switch method {
            case .trash:
                parts.append(failures.first?.entry.isFolder == true ? "Folder could not be moved" :
                    failures.count == 1 ? "1 file could not be moved" : "\(count) files could not be moved")
            case .permanent: parts.append(failures.count == 1 ? "1 file could not be deleted" : "\(count) files could not be deleted")
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
    private var submittedFileSearch = ""
    private var fileSearchSubmission = 0
    private(set) var fileFormat: FileFormat = .all
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
    private var previewFolderRevision = 0
    var previewFolderNames: [String] { previewGrants.keys.map { StorageStyle.location($0.path) }.sorted() }
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
        ThumbnailAccess(disk: foregroundAccess, folderRevision: previewFolderRevision)
    }
    var accessSetupError: String?
    var brokerProblem: String?
    var showsDetails = false
    var overview: Overview?
    private(set) var storageHistory: [StorageSample]?
    private(set) var storageOverview: Overview?
    var storageDays = 7
    private(set) var loadedGrowthDays: Int?
    private var storageRevision: String?
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
        let bookmarks = UserDefaults.standard.array(forKey: PreviewFolderGrant.preferenceKey) as? [Data] ?? []
        for bookmark in bookmarks {
            if let grant = PreviewFolderGrant.restore(bookmark) { previewGrants[grant.key] = grant }
        }
    }

    var isFixture: Bool { SpaceTrailPaths.fixtureRoot != nil }
    var backgroundRunning: Bool {
        guard let state, state.phase != .failed else { return false }
        // Versions that predate this field can still provide a live, registered agent.
        return state.background ?? (serviceStatus == .enabled && sessionProcess?.processIdentifier != state.pid)
    }
    var needsBackgroundApproval: Bool { wantsBackground && serviceStatus == .requiresApproval }
    var brokerStatus: String {
        if backgroundRunning { return "Automatic Updates" }
        if state?.phase == .failed { return "Updates Paused" }
        if state != nil { return "Updates While Open" }
        return "Starting Indexing"
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
        let submission: Int
        switch activeSection {
        case .folders: (scope, search, sort, submission) = (.children(folder), folderSearch, folderOrder.first, 0)
        case .search: (scope, search, sort, submission) = (.search, submittedSearch, globalOrder.first, searchSubmission)
        case .files, .map, .space:
            (scope, search, sort, submission) = (.files, submittedFileSearch, fileOrder.first, fileSearchSubmission)
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
                           filters: scope == .search ? submittedFilters : SearchFilters(format: scope == .files ? fileFormat : .all),
                           submission: submission, revision: revision)
    }

    var folderTitle: String {
        if folder.path == folder.tree.root { return folder.tree == .data ? volumeName : VolumeTree.systemDisplayName }
        return String(folder.path.split(separator: "/").last ?? "/")
    }

    var volumeName: String {
        if let fixture = SpaceTrailPaths.fixtureRoot {
            return URL(fileURLWithPath: fixture).lastPathComponent
        }
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? "Startup Disk"
    }

    var folderTrail: [(String, EntryKey)] { trail(to: folder) }

    func trail(to key: EntryKey) -> [(String, EntryKey)] {
        let root = key.tree.root
        let rootName = key.tree == .data ? volumeName : VolumeTree.systemDisplayName
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
            let showsStorage = activeSection == .space
            let growthDays = storageDays
            let needsHistory = showsStorage && (storageHistory == nil || storageRevision != revision)
            let result = try await readDashboard(since: needsHistory ? nil : revision, includeHistory: showsStorage)
            if let updated = result.overview {
                overview = updated
                if showsStorage, storageHistory != updated.history { storageHistory = updated.history }
                if revision != result.revision { revision = result.revision }
            }
            if result.revision != nil || currentState != nil { connectionError = nil }

            let savedStorageRevision = loadedGrowthDays == growthDays ? storageRevision : nil
            if showsStorage, let newest = result.revision, newest != savedStorageRevision {
                let detail = try await readDashboard(since: savedStorageRevision, includeDetails: true, days: growthDays)
                if let updated = detail.overview {
                    storageOverview = updated
                    storageRevision = detail.revision
                    loadedGrowthDays = growthDays
                    if storageHistory != updated.history { storageHistory = updated.history }
                }
            }
        } catch {
            if !Task.isCancelled, currentState?.phase != .preparing { connectionError = error.localizedDescription }
        }
    }

    private func readDashboard(since previous: String?, includeDetails: Bool = false, days: Int = 7,
                               includeHistory: Bool = false) async throws -> (revision: String?, overview: Overview?) {
        let reader = self.reader
        let read = Task.detached(priority: .utility) {
            try reader.dashboard(since: previous, includeDetails: includeDetails, growthDays: days,
                                 includeHistory: includeHistory)
        }
        let result = try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            read.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    func load(_ request: PageRequest, thumbnailSize: FileThumbnail.Size? = nil, thumbnailScale: CGFloat = 1) async {
        guard request.revision != nil else { return }
        if request.scope == .search {
            guard request.hasQuery else { return }
        } else if case .children = request.scope, !request.search.isEmpty, request.search != lastRequest?.search {
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

    func submitFileSearch() {
        submittedFileSearch = fileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        fileSearchSubmission += 1
        resetPage(clear: true)
    }

    func applySearchFilters() {
        guard request.hasQuery, searchFilters != submittedFilters,
              globalSearch.trimmingCharacters(in: .whitespacesAndNewlines) == submittedSearch else { return }
        submitSearch()
    }

    func selectFormat(_ format: FileFormat) {
        if activeSection == .search {
            searchFilters.format = format
            if format != .all, searchFilters.kind == .folders { searchFilters.kind = .files }
            submitSearch()
        } else if activeSection == .files {
            fileFormat = format
            submitFileSearch()
        }
    }

    func clearSearch() {
        globalSearch = ""
        submitSearch()
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
        else { reveal([entry]) }
    }

    func reveal(_ entries: [StorageEntry]) {
        let access = foregroundAccess
        Task {
            let missing = await Task.detached(priority: .userInitiated) {
                guard let access else { return [StorageEntry]() }
                return entries.filter { access.confirmsMissing($0.id) }
            }.value
            if !missing.isEmpty {
                hideRemoved(missing, inTrash: false)
                let paths = missing.filter { $0.id.tree == .data }.map(\.id.path)
                if !paths.isEmpty {
                    DistributedNotificationCenter.default().postNotificationName(
                        SpaceTrailPaths.verifyPathsNotification, object: reader.support.path,
                        userInfo: ["paths": paths], deliverImmediately: true
                    )
                }
                let message = missing.count == 1 ? "The item is no longer at its indexed location." :
                    "Some items are no longer at their indexed locations."
                AccessibilityNotification.Announcement(message).post()
            }
            let missingKeys = Set(missing.map(\.id))
            let urls = entries.filter { !missingKeys.contains($0.id) }.map { URL(fileURLWithPath: $0.id.path) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    func openFolderInFinder(_ key: EntryKey) {
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SpaceTrailPaths.displayPath(key.path)) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.path)])
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
        hideRemoved(report.removed + report.missing, inTrash: method == .trash)
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

    private func hideRemoved(_ entries: [StorageEntry], inTrash: Bool) {
        guard !entries.isEmpty else { return }
        let until = ContinuousClock.now + .seconds(30)
        for entry in entries {
            recentlyRemoved[entry.id] = RecentRemoval(inode: entry.inode, until: until,
                                                     inTrash: inTrash, isFolder: entry.isFolder)
        }
        rows.removeAll { hidesRemovedEntry($0) }
        selection.formIntersection(rows.lazy.map(\.id))
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
            connectionError = "SpaceTrail could not find the broker in the app bundle."
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
        guard let indexedURL = entry.previewURL else { return nil }
        if entry.id.protectedAppDataScope == nil, foregroundAccess?.includes(entry.id) == true { return indexedURL }
        guard let parent = entry.parent,
              let grant = previewGrant(for: EntryKey(tree: entry.id.tree, path: parent)) else { return nil }
        return grant.source(for: entry.id)
    }

    private func previewGrant(for folder: EntryKey) -> PreviewFolderGrant? {
        previewGrants.values.first { $0.covers(folder) }
    }

    func previewAccessFolder(in folder: EntryKey) -> EntryKey? {
        guard PreviewFolderGrant.allows(folder), previewGrant(for: folder) == nil,
              folder.protectedAppDataScope != nil || foregroundAccess?.includes(folder) == false else { return nil }
        return PreviewFolderGrant.suggestedFolder(for: folder)
    }

    func choosePreviewFolders(startingIn folder: EntryKey? = nil) async -> String? {
        let requested = folder.map { URL(fileURLWithPath: SpaceTrailPaths.displayPath($0.path), isDirectory: true) }
        if let folder, let requested, await PreviewFolderGrant.hasExistingAccess(to: folder, at: requested),
           let grant = PreviewFolderGrant.selected(requested), grant.covers(folder) {
            return savePreviewGrants([grant])
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.canCreateDirectories = false
        panel.directoryURL = requested ?? FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Allow Previews"
        if let folder {
            let name = (folder.path as NSString).lastPathComponent
            panel.message = "Select “\(name)” to preview files in this folder and its subfolders."
        } else {
            panel.message = "Choose personal folders to preview their files and subfolders."
        }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK else { return nil }
        let grants = panel.urls.compactMap(PreviewFolderGrant.selected)
        let saveError = savePreviewGrants(grants)
        if grants.count != panel.urls.count {
            return "Choose a specific folder in your home folder. This includes folders for individual apps."
        }
        return saveError
    }

    private func savePreviewGrants(_ grants: [PreviewFolderGrant]) -> String? {
        for grant in grants { previewGrants[grant.key] = grant }
        if !grants.isEmpty {
            previewFolderRevision += 1
            UserDefaults.standard.set(previewGrants.values.compactMap(\.bookmark), forKey: PreviewFolderGrant.preferenceKey)
        }
        if grants.contains(where: { $0.bookmark == nil }) {
            return "Some folders are available for this session. macOS couldn’t save their access for later."
        }
        return nil
    }

    func forgetPreviewFolders() {
        previewGrants.removeAll()
        previewFolderRevision += 1
        searchThumbnails.removeAll()
        ThumbnailResources.shared.clear()
        UserDefaults.standard.removeObject(forKey: PreviewFolderGrant.preferenceKey)
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

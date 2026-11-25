import Darwin
import Foundation
import SpaceTrailCore

final class PreviewFolderGrant {
    static let preferenceKey = "previewFolderBookmarks"
    private static let personalLocations: Set<Substring> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
    private static let macOSFolderPermissions: Set<Substring> = ["Desktop", "Documents", "Downloads"]

    let key: EntryKey
    let url: URL
    let bookmark: Data?
    private let hasScope: Bool

    private init?(url: URL, savedBookmark: Data? = nil, requiresScope: Bool = false) {
        let hasScope = url.startAccessingSecurityScopedResource()
        guard hasScope || !requiresScope else { return nil }
        let path = SpaceTrailPaths.displayPath(url.resolvingSymlinksInPath().standardizedFileURL.path)
        let key = EntryKey(tree: .data, path: VolumeTree.data.root + path)
        guard Self.allows(key) else {
            if hasScope { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.key = key
        self.url = url
        self.hasScope = hasScope
        bookmark = savedBookmark ?? (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
    }

    deinit {
        if hasScope { url.stopAccessingSecurityScopedResource() }
    }

    static func allows(_ folder: EntryKey) -> Bool {
        guard let home = SpaceTrailPaths.personalFolder, folder.tree == home.tree,
              folder.path.hasPrefix(home.path + "/") else { return false }
        if let scope = folder.protectedAppDataScope {
            // Require a specific app's folder or a descendant selected in the system picker.
            return folder.path.hasPrefix(scope.path + "/")
        }
        let parts = folder.path.dropFirst(home.path.count + 1).split(separator: "/")
        guard let root = parts.first else { return false }
        return personalLocations.contains(root) || (root == "Library" && parts.count > 1)
    }

    static func suggestedFolder(for folder: EntryKey) -> EntryKey {
        guard let home = SpaceTrailPaths.personalFolder,
              let root = folder.path.dropFirst(home.path.count + 1).split(separator: "/").first,
              personalLocations.contains(root) else { return folder }
        return EntryKey(tree: folder.tree, path: home.path + "/" + root)
    }

    static func selected(_ url: URL) -> PreviewFolderGrant? {
        PreviewFolderGrant(url: url)
    }

    static func restore(_ data: Data) -> PreviewFolderGrant? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 bookmarkDataIsStale: &stale) else { return nil }
        return PreviewFolderGrant(url: url, savedBookmark: stale ? nil : data, requiresScope: true)
    }

    // Only try a Files and Folders permission when someone selects that exact
    // location in SpaceTrail. Browsing the index never runs this check.
    static func hasExistingAccess(to folder: EntryKey, at url: URL) async -> Bool {
        guard let home = SpaceTrailPaths.personalFolder, folder.tree == home.tree,
              folder.path.hasPrefix(home.path + "/"),
              macOSFolderPermissions.contains(folder.path.dropFirst(home.path.count + 1)) else { return false }
        return await Task.detached(priority: .userInitiated) {
            guard let directory = opendir(url.path) else { return false }
            defer { closedir(directory) }
            errno = 0
            return readdir(directory) != nil || errno == 0
        }.value
    }

    func covers(_ folder: EntryKey) -> Bool {
        key.tree == folder.tree && (folder.path == key.path || folder.path.hasPrefix(key.path + "/"))
    }

    func source(for entry: EntryKey) -> URL {
        let relative = entry.path.dropFirst(key.path.count + 1)
        return url.appendingPathComponent(String(relative), isDirectory: false)
    }
}

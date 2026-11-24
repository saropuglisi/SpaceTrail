import Darwin
import Foundation

public enum FileDeletion {
    public enum Failure: LocalizedError {
        case unavailable
        case changed
        case missing
        case system(Int32)

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "L’elemento si trova in una posizione protetta."
            case .changed: return "L’elemento è cambiato. Selezionalo di nuovo dopo l’aggiornamento dell’indice."
            case .missing: return "L’elemento è già stato rimosso."
            case .system(let code) where code == EPERM || code == EACCES:
                return "macOS impedisce la rimozione di questo elemento."
            case .system(let code): return String(cString: strerror(code))
            }
        }
    }

    private static let protectedPaths = [SpaceTrailPaths.support.path, Bundle.main.bundleURL.path]
        .map(SpaceTrailPaths.identityPath)
    private static let protectedHomeFolders: Set<String> = ["library", "applications", "system"]
    private static let standardHomeFolders: Set<String> = [
        "desktop", "documents", "downloads", "movies", "music", "pictures", "public", "sites"
    ]
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "component", "framework", "kext", "mdimporter", "photoslibrary",
        "plugin", "prefpane", "qlgenerator", "systemextension", "vst", "vst3", "xpc"
    ]

    public static var trashDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    public static func isProtected(_ key: EntryKey) -> Bool {
        guard key.tree == .data, let home = SpaceTrailPaths.personalFolder,
              key.path.hasPrefix(home.path + "/") else { return true }
        let relative = key.path.dropFirst(home.path.count + 1)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first?.lowercased(), !protectedHomeFolders.contains(first) else { return true }
        if parts.enumerated().contains(where: { index, part in
            let hidden = part.hasPrefix(".") && (index != 0 || first != ".trash")
            return part.isEmpty || hidden || packageExtensions.contains((String(part) as NSString).pathExtension.lowercased())
        }) { return true }
        let path = SpaceTrailPaths.identityPath(key.path)
        return protectedPaths.contains(where: { isWithin(path, $0) })
    }

    public static func canRemove(_ entry: StorageEntry, access: DiskAccess) -> Bool {
        entry.parent != nil && (entry.kind == .file || entry.kind == .symbolicLink)
            && !isProtected(entry.id) && access.includes(entry.id)
    }

    public static func canMoveToTrash(_ entry: StorageEntry, access: DiskAccess) -> Bool {
        guard let home = SpaceTrailPaths.personalFolder, entry.parent != nil,
              !isWithin(entry.id.path.lowercased(), childPath(home.path, ".Trash").lowercased()) else { return false }
        guard entry.isFolder else { return canRemove(entry, access: access) }
        guard !isProtected(entry.id), access.includes(entry.id),
              entry.parent != home.path || !standardHomeFolders.contains(entry.name.lowercased()) else { return false }
        let path = SpaceTrailPaths.identityPath(entry.id.path).lowercased()
        return !protectedPaths.contains(where: { isWithin($0.lowercased(), path) })
    }

    @discardableResult
    public static func moveToTrash(_ entry: StorageEntry, access: DiskAccess) throws -> URL? {
        guard canMoveToTrash(entry, access: access) else { throw Failure.unavailable }
        return try withVerifiedItem(entry) { _, _, verified in
            // Foundation resolves the path again. Check the file at that path before moving it.
            let url = URL(fileURLWithPath: entry.id.path)
            var current = stat()
            guard lstat(entry.id.path, &current) == 0 else { throw failure(errno) }
            guard current.st_dev == verified.st_dev, matches(current, entry) else { throw Failure.changed }

            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            return destination as URL?
        }
    }

    public static func isCurrent(_ entry: StorageEntry, access: DiskAccess) -> Bool {
        guard canRemove(entry, access: access) || canMoveToTrash(entry, access: access) else { return false }
        return (try? withVerifiedItem(entry) { _, _, _ in true }) ?? false
    }

    /// Remove only the indexed file or link, without following a parent that was replaced by a link.
    public static func remove(_ entry: StorageEntry, access: DiskAccess) throws {
        guard canRemove(entry, access: access) else { throw Failure.unavailable }
        try withVerifiedItem(entry) { directory, name, _ in
            guard unlinkat(directory, name, 0) == 0 else { throw failure(errno) }
        }
    }

    private static func withVerifiedItem<T>(_ entry: StorageEntry,
                                            perform: (Int32, String, stat) throws -> T) throws -> T {
        let root = entry.id.tree.root
        guard entry.id.path != root else { throw Failure.unavailable }
        let parts = entry.id.path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard let leaf = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw Failure.changed
        }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directory = open(root, flags)
        guard directory >= 0 else { throw failure(errno) }
        defer { close(directory) }
        var volume = stat()
        guard fstat(directory, &volume) == 0 else { throw failure(errno) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), flags)
            guard next >= 0 else { throw failure(errno) }
            close(directory)
            directory = next
        }

        let name = String(leaf)
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(errno) }
        guard info.st_dev == volume.st_dev, matches(info, entry) else { throw Failure.changed }
        let protectedFlags = UInt32(SF_RESTRICTED | SF_NOUNLINK | SF_IMMUTABLE | UF_IMMUTABLE)
        guard info.st_uid == geteuid(), info.st_flags & protectedFlags == 0 else { throw Failure.unavailable }
        var parent = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directory, F_GETPATH, &parent) == 0 else { throw failure(errno) }
        guard let expectedParent = parentPath(entry.id.path),
              SpaceTrailPaths.identityPath(String(cString: parent)) == SpaceTrailPaths.identityPath(expectedParent)
        else { throw Failure.changed }
        return try perform(directory, name, info)
    }

    private static func matches(_ info: stat, _ entry: StorageEntry) -> Bool {
        let expectedType: mode_t
        switch entry.kind {
        case .file: expectedType = S_IFREG
        case .symbolicLink: expectedType = S_IFLNK
        case .directory: expectedType = S_IFDIR
        case .other: return false
        }
        return info.st_mode & S_IFMT == expectedType && Int64(bitPattern: info.st_ino) == entry.inode &&
            fileDate(info.st_birthtimespec) == entry.created && fileDate(info.st_mtimespec) == entry.modified &&
            (entry.isFolder || max(0, info.st_size) == entry.logical)
    }

    private static func failure(_ code: Int32) -> Failure {
        switch code {
        case ENOENT: return .missing
        case ELOOP, ENOTDIR: return .changed
        default: return .system(code)
        }
    }
}

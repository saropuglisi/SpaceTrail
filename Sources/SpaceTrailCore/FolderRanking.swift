import Foundation

enum FolderRanking {
    // These are operating-system branches on the writable volume, rather than
    // separate content a person can usefully inspect in a storage ranking.
    private static let systemBranches = [
        "System", "private", "usr", "bin", "sbin", "dev", "Volumes", "cores",
        ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems"
    ]
    private static let libraryBuckets: Set<Substring> = [
        "Application Support", "Application Scripts", "Caches", "CloudStorage",
        "Containers", "Group Containers", "Logs", "Mobile Documents", "Preferences", "Saved Application State"
    ]

    static func load(from db: SQLiteConnection, limit: Int = 8, preferFootprints: Bool = false) throws -> [StorageEntry] {
        guard limit > 0 else { return [] }
        let root = VolumeTree.data.root
        let excluded = systemBranches.map { childPath(root, $0) }
        let predicates = excluded.map { _ in "AND e.path <> ? AND (e.path < ? OR e.path >= ?)" }.joined(separator: " ")
        let bindings = excluded.flatMap { path -> [SQLValue] in
            [.text(path), .text(path + "/"), .text(path + "0")]
        }
        var folders: [StorageEntry] = []
        let columns = entryColumns.split(separator: " ").map { "e." + $0 }.joined(separator: " ")
        let eligible = "e.kind = 1 AND e.tree = 0 AND e.parent IS NOT NULL AND e.allocated > 0 \(predicates)"
        func append(from source: String, filter: String = "", order: String) throws {
            try db.queryWhile("""
                SELECT \(columns) FROM \(source) WHERE \(eligible) \(filter) ORDER BY \(order)
                """, bindings) { row in
                let entry = indexEntry(row)
                guard isSpecific(entry.id.path, in: root),
                      !folders.contains(where: { isWithin(entry.id.path, $0.id.path) || isWithin($0.id.path, entry.id.path) })
                else { return true }
                folders.append(entry)
                return folders.count < limit
            }
        }
        if preferFootprints {
            try append(from: """
                folder_footprints f INDEXED BY folder_footprint_size CROSS JOIN entries e ON e.rowid = f.entry_id
                """, filter: "AND f.measured > 0 AND f.exclusive + f.shared > 0",
                       order: "f.exclusive + f.shared DESC")
        }
        if folders.count < limit {
            try append(from: "entries e INDEXED BY folder_allocated", order: "e.allocated DESC, e.path ASC")
        }
        return folders
    }

    private static func isSpecific(_ path: String, in root: String) -> Bool {
        let relative = path.dropFirst(root == "/" ? 1 : root.count)
        let parts = relative.split(separator: "/")
        guard let first = parts.first else { return false }
        switch first {
        case "Users":
            guard parts.count >= 3 else { return false }
            return parts[2] != "Library" || isSpecificLibrary(parts.dropFirst(3))
        case "Library":
            return isSpecificLibrary(parts.dropFirst())
        case "Applications":
            return parts.count > 1
        default:
            return true
        }
    }

    private static func isSpecificLibrary(_ relativeParts: ArraySlice<Substring>) -> Bool {
        guard let first = relativeParts.first else { return false }
        return relativeParts.count > 1 || !libraryBuckets.contains(first)
    }
}

import SQLite3

enum IndexSchema: Int64 {
    case fullPaths = 0
    case compactParents = 1
    case directoryReferences = 2

    static let current = Self.directoryReferences

    static func read(from db: SQLiteConnection) throws -> Self {
        guard let schema = Self(rawValue: try db.integer("PRAGMA user_version")) else {
            throw SQLiteFailure(code: SQLITE_ERROR, operation: "version",
                                message: "This index requires a newer version of SpaceTrail.")
        }
        return schema
    }

    var hasParentReferences: Bool { self != .fullPaths }

    var locationColumn: String { self == .directoryReferences ? "directory" : "path" }

    static let childPath = "CASE WHEN p.path = '/' THEN '/' || e.name ELSE p.path || '/' || e.name END"
    static let directoryRange = """
        p.tree = ? AND p.path >= ? AND p.path < ? AND (p.path = ? OR p.path >= ?)
        """

    var path: String {
        guard self == .directoryReferences else { return "e.path" }
        // Only roots need their own reference to materialize a path.
        return """
            (SELECT CASE
                WHEN e.parent IS NULL THEN p.path
                WHEN p.path = '/' THEN '/' || e.name
                ELSE p.path || '/' || e.name END
             FROM parent_paths p WHERE p.id = COALESCE(e.parent, e.directory))
            """
    }

    func columns(path: String? = nil) -> String {
        """
        e.tree, \(path ?? self.path), e.parent, e.name, e.name_key, e.kind, e.logical,
        e.allocated, e.files, e.modified, e.created, e.inode, e.mode, e.links, e.rowid
        """
    }

    func location(_ key: EntryKey) -> (predicate: String, values: [SQLValue]) {
        guard self == .directoryReferences else { return ("e.tree = ? AND e.path = ?", key.values) }
        if key.path == key.tree.root {
            return ("e.tree = ? AND e.parent IS NULL", [.int(key.tree.rawValue)])
        }
        let parent = EntryKey(tree: key.tree, path: parentPath(key.path) ?? "")
        return ("e.parent = (SELECT id FROM parent_paths WHERE tree = ? AND path = ?) AND e.name = ?",
                parent.values + [.text(pathName(key.path))])
    }

    func children(_ key: EntryKey) -> (predicate: String, values: [SQLValue]) {
        if hasParentReferences {
            return ("e.tree = ? AND e.parent = (SELECT id FROM parent_paths WHERE tree = ? AND path = ?)",
                    [.int(key.tree.rawValue)] + key.values)
        }
        return ("e.tree = ? AND e.parent = ?", key.values)
    }
}

import Foundation
import SQLite3

struct Totals: Equatable {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var files: Int64 = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(logical: lhs.logical + rhs.logical, allocated: lhs.allocated + rhs.allocated, files: lhs.files + rhs.files)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(logical: lhs.logical - rhs.logical, allocated: lhs.allocated - rhs.allocated, files: lhs.files - rhs.files)
    }
}

let entryMetadataColumns = "parent, name, name_key, kind, logical, allocated, files, modified, created, inode, mode, links"

struct IndexedEntry {
    let rowID: Int64
    let entry: StorageEntry

    init(_ row: OpaquePointer) {
        rowID = sqlInt(row, 14)
        entry = indexEntry(row)
    }
}

func indexEntry(_ row: OpaquePointer) -> StorageEntry {
    let path = sqlText(row, 1) ?? ""
    let tree = VolumeTree(rawValue: sqlInt(row, 0)) ?? .data
    return StorageEntry(
        id: EntryKey(tree: tree, path: path),
        parent: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : parentPath(path),
        name: tree == .system && path == tree.root ? VolumeTree.systemDisplayName : sqlText(row, 3) ?? "",
        kind: EntryKind(rawValue: sqlInt(row, 5)) ?? .other,
        logical: sqlInt(row, 6),
        allocated: sqlInt(row, 7),
        files: sqlInt(row, 8),
        modified: Date(timeIntervalSince1970: sqlReal(row, 9)),
        created: Date(timeIntervalSince1970: sqlReal(row, 10)),
        inode: sqlInt(row, 11),
        mode: sqlInt(row, 12),
        links: sqlInt(row, 13)
    )
}

extension StorageEntry {
    var totals: Totals { Totals(logical: logical, allocated: allocated, files: files) }
}

extension EntryKey {
    var values: [SQLValue] { [.int(tree.rawValue), .text(path)] }

    var subtreeValues: [SQLValue] {
        let stem = path == "/" ? "" : path
        return values + [.text(stem + "/"), .text(stem + "0")]
    }

    func directoryRangeValues(startingAt directory: String? = nil) -> [SQLValue] {
        let stem = path == "/" ? "" : path
        return [.int(tree.rawValue), .text(directory ?? path), .text(stem + "0"), .text(path), .text(stem + "/")]
    }
}

let subtreeWhere = "tree = ? AND (path = ? OR (path >= ? AND path < ?))"

func parentPath(_ path: String) -> String? {
    guard path != "/", let separator = path.lastIndex(of: "/") else { return nil }
    return separator == path.startIndex ? "/" : String(path[..<separator])
}

func pathName(_ path: String) -> String {
    guard let separator = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: separator)...])
}

func childPath(_ parent: String, _ child: String) -> String {
    parent == "/" ? "/" + child : parent + "/" + child
}

func isWithin(_ path: String, _ base: String) -> Bool {
    path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
}

final class IndexWriter {
    let db: SQLiteConnection
    let schema: IndexSchema
    private let support: URL
    lazy var footprints = FootprintIndex(db: db, schema: schema)

    static let reserve: Int64 = 512 * 1_048_576

    init(support: URL, deferIndexes: Bool = false) throws {
        self.support = support
        db = try SQLiteConnection(SpaceTrailPaths.database(in: support), readOnly: false)
        let newIndex = try db.integer("SELECT count(*) FROM sqlite_schema WHERE name = 'entries'") == 0
        schema = newIndex ? .current : try IndexSchema.read(from: db)
        if newIndex { try db.run("PRAGMA auto_vacuum = INCREMENTAL") }
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA wal_autocheckpoint = 1024;
            PRAGMA journal_size_limit = 8388608;
            PRAGMA cache_size = -12288;
            PRAGMA temp_store = FILE;
            PRAGMA temp.cache_size = -2048;
            """)
        try db.transaction("BEGIN IMMEDIATE") {
            if schema.hasParentReferences {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS parent_paths (
                        id INTEGER PRIMARY KEY, tree INTEGER NOT NULL, path TEXT NOT NULL, UNIQUE(tree, path)
                    );
                    """)
            }
            let location = schema == .directoryReferences ? "directory INTEGER" : "path TEXT NOT NULL"
            let primaryKey: String
            switch schema {
            case .directoryReferences: primaryKey = "id INTEGER PRIMARY KEY"
            case .compactParents: primaryKey = "id INTEGER PRIMARY KEY, UNIQUE(tree, path)"
            case .fullPaths: primaryKey = "PRIMARY KEY(tree, path)"
            }
            try db.execute("""
                CREATE TABLE IF NOT EXISTS entries (
                    tree INTEGER NOT NULL,
                    \(location),
                    parent \(schema.hasParentReferences ? "INTEGER" : "TEXT"),
                    name TEXT NOT NULL,
                    name_key TEXT NOT NULL,
                    kind INTEGER NOT NULL,
                    logical INTEGER NOT NULL,
                    allocated INTEGER NOT NULL,
                    files INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    created REAL NOT NULL,
                    inode INTEGER NOT NULL,
                    mode INTEGER NOT NULL,
                    links INTEGER NOT NULL,
                    \(primaryKey)
                );
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS gaps (tree INTEGER, path TEXT, retry_after REAL NOT NULL, PRIMARY KEY(tree, path)) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS gap_retry ON gaps(retry_after, tree, path);
                CREATE TABLE IF NOT EXISTS samples (
                    date INTEGER PRIMARY KEY,
                    capacity INTEGER NOT NULL,
                    available INTEGER NOT NULL,
                    indexed INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pending_scan (
                    tree INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(tree, path)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS pending_repair (
                    tree INTEGER NOT NULL, path TEXT NOT NULL, mode INTEGER NOT NULL, PRIMARY KEY(tree, path)
                ) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS repair_by_mode ON pending_repair(mode DESC, tree, path);
                CREATE TABLE IF NOT EXISTS limited_scopes (
                    tree INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(tree, path)
                ) WITHOUT ROWID;
                CREATE TEMP TABLE seen (name TEXT PRIMARY KEY) WITHOUT ROWID;
                """)
            try footprints.createTables()
            if newIndex { try db.run("PRAGMA user_version = \(schema.rawValue)") }
            if !deferIndexes {
                try createIndexes()
                try createSearch()
            }
        }
        // Recover and reclaim any abandoned WAL before building the new index.
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func createIndexes() throws {
        try db.execute("""
            CREATE INDEX IF NOT EXISTS children ON entries(tree, parent, logical);
            CREATE INDEX IF NOT EXISTS file_size ON entries(logical) WHERE kind <> 1;
            CREATE INDEX IF NOT EXISTS file_allocated ON entries(allocated) WHERE kind <> 1;
            CREATE INDEX IF NOT EXISTS entry_name ON entries(name_key);
            DROP INDEX IF EXISTS file_name;
            CREATE INDEX IF NOT EXISTS file_modified ON entries(modified) WHERE kind <> 1;
            CREATE INDEX IF NOT EXISTS folder_allocated ON entries(allocated)
                WHERE kind = 1 AND parent IS NOT NULL;
            """)
        if schema == .directoryReferences {
            try db.execute("""
                CREATE UNIQUE INDEX IF NOT EXISTS entry_location ON entries(parent, name) WHERE parent IS NOT NULL;
                CREATE UNIQUE INDEX IF NOT EXISTS folder_path ON entries(directory) WHERE directory IS NOT NULL;
                CREATE UNIQUE INDEX IF NOT EXISTS index_roots ON entries(tree) WHERE parent IS NULL;
                """)
        } else {
            try db.execute("""
                CREATE INDEX IF NOT EXISTS folder_path ON entries(tree, path) WHERE kind = 1;
                CREATE INDEX IF NOT EXISTS index_roots ON entries(tree) WHERE parent IS NULL;
                """)
        }
        try footprints.createIndexes()
    }

    func createSearch() throws {
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS name_fts USING fts5(
                name_key, content='entries', tokenize='trigram case_sensitive 1', detail=none, columnsize=0
            );
            CREATE TRIGGER IF NOT EXISTS search_insert AFTER INSERT ON entries BEGIN
                INSERT INTO name_fts(rowid, name_key) VALUES (new.rowid, new.name_key);
            END;
            CREATE TRIGGER IF NOT EXISTS search_delete AFTER DELETE ON entries BEGIN
                INSERT INTO name_fts(name_fts, rowid, name_key) VALUES ('delete', old.rowid, old.name_key);
            END;
            CREATE TRIGGER IF NOT EXISTS search_rename AFTER UPDATE OF name_key ON entries
            WHEN new.name_key <> old.name_key BEGIN
                INSERT INTO name_fts(name_fts, rowid, name_key) VALUES ('delete', old.rowid, old.name_key);
                INSERT INTO name_fts(rowid, name_key) VALUES (new.rowid, new.name_key);
            END;
            """)
    }

    func checkDiskSpace() throws {
        let available = try mountInfo(support.path).available
        guard available >= Self.reserve else {
            throw SQLiteFailure(code: SQLITE_FULL, operation: "indexing", message: "Insufficient disk space")
        }
    }

    func reclaimSpace() throws {
        guard schema.hasParentReferences, try db.integer("PRAGMA freelist_count") >= 1_024 else { return }
        try db.run("PRAGMA incremental_vacuum(2048)")
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func finishBatch() throws {
        try db.execute("COMMIT")
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        try checkDiskSpace()
        try db.execute("BEGIN IMMEDIATE")
    }

    func prepareInitialScan() throws {
        // Entries without a baseline were never published to readers. Clear them in bounded writes.
        try checkDiskSpace()
        try set("initialWatermark", "0")
        while true {
            var last: Int64?
            try db.query("SELECT rowid FROM entries ORDER BY rowid LIMIT 1 OFFSET 8191") { last = sqlInt($0, 0) }
            guard let last else {
                try db.execute("DELETE FROM entries; DELETE FROM gaps; DELETE FROM pending_scan; DELETE FROM limited_scopes; DELETE FROM pending_repair;")
                if schema.hasParentReferences { try db.run("DELETE FROM parent_paths") }
                break
            }
            try db.run("DELETE FROM entries WHERE rowid <= ?", [.int(last)])
        }
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func queueInitial(_ key: EntryKey) throws {
        try db.run("INSERT OR IGNORE INTO pending_scan VALUES (?, ?)", key.values)
    }

    func nextInitial() throws -> EntryKey? {
        var result: EntryKey?
        try db.query("SELECT tree, path FROM pending_scan ORDER BY tree, path LIMIT 1") { row in
            if let tree = VolumeTree(rawValue: sqlInt(row, 0)), let path = sqlText(row, 1) {
                result = EntryKey(tree: tree, path: path)
            }
        }
        return result
    }

    func finishInitialDirectory(_ key: EntryKey) throws {
        try db.run("DELETE FROM pending_scan WHERE tree = ? AND path = ?", key.values)
    }

    func directTotals(_ key: EntryKey) throws -> Totals {
        var result = Totals()
        let children = schema.children(key)
        try db.query("""
            SELECT COALESCE(sum(logical), 0), COALESCE(sum(allocated), 0), COALESCE(sum(files), 0)
            FROM entries e WHERE \(children.predicate)
            """, children.values) {
            result = Totals(logical: sqlInt($0, 0), allocated: sqlInt($0, 1), files: sqlInt($0, 2))
        }
        return result
    }

    func prepareSearch(existingBaseline: Bool) throws {
        guard try metadata("searchComplete") != "1" else { return }
        if existingBaseline {
            var cursor = try metadata("searchCursor").flatMap(Int64.init) ?? 0
            while true {
                var rows: Int64 = 0
                var end = cursor
                try db.query("SELECT count(*), COALESCE(max(rowid), 0) FROM (SELECT rowid FROM entries WHERE rowid > ? ORDER BY rowid LIMIT 8192)", [.int(cursor)]) {
                    rows = sqlInt($0, 0)
                    end = sqlInt($0, 1)
                }
                guard rows > 0 else { break }
                try checkDiskSpace()
                try db.transaction("BEGIN IMMEDIATE") {
                    try db.run("INSERT INTO name_fts(rowid, name_key) SELECT rowid, name_key FROM entries WHERE rowid > ? AND rowid <= ?", [.int(cursor), .int(end)])
                    try set("searchCursor", String(end))
                }
                cursor = end
            }
        }
        try set("searchComplete", "1")
    }

    func metadata(_ name: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(name)]) { value = sqlText($0, 0) }
        return value
    }

    func set(_ name: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta VALUES (?, ?)", [.text(name), .text(value)])
    }

    func entry(_ key: EntryKey) throws -> StorageEntry? {
        var result: StorageEntry?
        let location = schema.location(key)
        try db.query("SELECT \(schema.columns()) FROM entries e WHERE \(location.predicate)", location.values) {
            result = indexEntry($0)
        }
        return result
    }

    func insert(_ entry: StorageEntry) throws {
        var parent: SQLValue = .null
        if let path = entry.parent {
            parent = schema.hasParentReferences ? .int(try directoryID(EntryKey(tree: entry.id.tree, path: path))) : .text(path)
        }
        let location: SQLValue
        if schema == .directoryReferences {
            location = entry.isFolder || entry.parent == nil ? .int(try directoryID(entry.id)) : .null
        } else {
            location = .text(entry.id.path)
        }
        let column = schema.locationColumn
        try db.run("""
            INSERT INTO entries (tree, \(column), \(entryMetadataColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO UPDATE SET \(column)=excluded.\(column), parent=excluded.parent, name=excluded.name,
                name_key=excluded.name_key, kind=excluded.kind, logical=excluded.logical,
                allocated=excluded.allocated, files=excluded.files, modified=excluded.modified,
                created=excluded.created, inode=excluded.inode, mode=excluded.mode, links=excluded.links
            """, [
                .int(entry.id.tree.rawValue), location,
                parent, .text(entry.name), .text(foldedName(entry.name)),
                .int(entry.kind.rawValue), .int(entry.logical), .int(entry.allocated), .int(entry.files),
                .real(entry.modified.timeIntervalSince1970), .real(entry.created.timeIntervalSince1970),
                .int(entry.inode), .int(entry.mode), .int(entry.links)
            ])
    }

    private func directoryID(_ key: EntryKey) throws -> Int64 {
        let lookup = "SELECT id FROM parent_paths WHERE tree = ? AND path = ?"
        let existing = try db.integer(lookup, key.values)
        if existing != 0 { return existing }
        try db.run("INSERT INTO parent_paths(tree, path) VALUES (?, ?)", key.values)
        return try db.integer(lookup, key.values)
    }

    func scheduleRepair(_ key: EntryKey, mode: RepairMode = .walk) throws {
        try db.run("""
            INSERT INTO pending_repair VALUES (?, ?, ?)
            ON CONFLICT(tree, path) DO UPDATE SET mode = max(mode, excluded.mode)
            """, key.values + [.int(mode.rawValue)])
    }

    func nextRepair() throws -> (key: EntryKey, mode: RepairMode)? {
        var result: (EntryKey, RepairMode)?
        try db.query("SELECT tree, path, mode FROM pending_repair ORDER BY mode DESC, tree, path LIMIT 1") {
            if let tree = VolumeTree(rawValue: sqlInt($0, 0)), let path = sqlText($0, 1),
               let mode = RepairMode(rawValue: sqlInt($0, 2)) {
                result = (EntryKey(tree: tree, path: path), mode)
            }
        }
        return result
    }

    func completeRepair(_ key: EntryKey, mode: RepairMode) throws {
        try db.run("DELETE FROM pending_repair WHERE tree = ? AND path = ? AND mode = ?",
                   key.values + [.int(mode.rawValue)])
    }

    func rememberLimited(_ key: EntryKey) throws {
        try db.run("INSERT OR IGNORE INTO limited_scopes VALUES (?, ?)", key.values)
    }

    func scheduleLimitedScopes() throws {
        try db.run("INSERT OR IGNORE INTO pending_repair SELECT tree, path, 0 FROM limited_scopes")
        try db.run("DELETE FROM limited_scopes")
    }

    func migrateSystemAliases(scheduleSystemRepair: Bool) throws {
        // Keep the old topology marker until every alias has been removed. A restart can
        // safely skip an already pruned branch and views continue to show the data tree.
        for path in StartupVolumeLayout.systemAliases {
            try db.transaction("BEGIN IMMEDIATE") { try prune(EntryKey(tree: .system, path: path)) }
            try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try db.transaction("BEGIN IMMEDIATE") {
            if scheduleSystemRepair {
                try scheduleRepair(EntryKey(tree: .system, path: "/"))
            }
            try set("topology", StartupVolumeLayout.version)
            try set("revision", UUID().uuidString)
        }
    }

    /// Keep the old aggregate at the subtree root until all descendants have been removed.
    /// A crash between batches leaves that root and its removal job available on restart.
    func prune(_ key: EntryKey) throws {
        let previous = try entry(key)
        var lastDirectory = key.path == "/" ? "0" : key.path + "0"
        while try deleteDescendants(key, through: &lastDirectory, limit: 4_096) == 4_096 {
            try finishBatch()
        }
        try deleteEntry(key)
        if schema.hasParentReferences { try db.run("DELETE FROM parent_paths WHERE \(subtreeWhere)", key.subtreeValues) }
        try deleteGaps(in: key)
        if let previous { try adjustAncestors(of: key, by: Totals() - previous.totals) }
    }

    private func deleteDescendants(_ key: EntryKey, through lastDirectory: inout String, limit: Int64) throws -> Int {
        let descendants: String
        let values: [SQLValue]
        if schema == .directoryReferences {
            descendants = """
                SELECT e.rowid AS entry_id, \(IndexSchema.childPath) AS path, p.path AS directory_path
                FROM parent_paths p CROSS JOIN entries e ON e.parent = p.id
                WHERE \(IndexSchema.directoryRange) AND p.path <= ?
                ORDER BY p.path DESC, e.name DESC LIMIT ?
                """
            values = key.directoryRangeValues() + [.text(lastDirectory), .int(limit)]
        } else {
            descendants = """
                SELECT rowid AS entry_id, path, NULL AS directory_path FROM entries
                WHERE tree = ? AND path <> ? AND path >= ? AND path < ? ORDER BY path DESC LIMIT ?
                """
            values = key.subtreeValues + [.int(limit)]
        }
        var removed: [FootprintIndex.Change] = []
        try db.query("""
            SELECT d.entry_id, d.path, d.directory_path, f.entry_id IS NOT NULL
            FROM (\(descendants)) d LEFT JOIN file_footprints f ON f.entry_id = d.entry_id
            ORDER BY d.directory_path DESC
            """, values) {
            if let directory = sqlText($0, 2) { lastDirectory = directory }
            if sqlInt($0, 3) != 0, let path = sqlText($0, 1) {
                removed.append(.init(rowID: sqlInt($0, 0), key: EntryKey(tree: key.tree, path: path), footprint: nil))
            }
        }
        try footprints.apply(removed, trackPeers: true)
        try db.run("DELETE FROM entries WHERE rowid IN (SELECT entry_id FROM (\(descendants)))", values)
        return db.changes
    }

    func forgetFootprint(_ key: EntryKey, trackPeers: Bool = true) throws {
        let location = schema.location(key)
        let id = try db.integer("""
            SELECT f.entry_id FROM entries e JOIN file_footprints f ON f.entry_id = e.rowid
            WHERE \(location.predicate)
            """, location.values)
        if id != 0 { try footprints.apply([.init(rowID: id, key: key, footprint: nil)], trackPeers: trackPeers) }
    }

    func deleteEntry(_ key: EntryKey, trackPeers: Bool = true) throws {
        try forgetFootprint(key, trackPeers: trackPeers)
        let location = schema.location(key)
        try db.run("DELETE FROM entries AS e WHERE \(location.predicate)", location.values)
    }

    private func deleteGaps(in key: EntryKey) throws {
        try db.run("DELETE FROM gaps WHERE \(subtreeWhere)", key.subtreeValues)
    }

    func adjustAncestors(of key: EntryKey, by delta: Totals) throws {
        guard delta != Totals(), key.path != key.tree.root else { return }
        var next = parentPath(key.path)
        while let parent = next, isWithin(parent, key.tree.root) {
            let location = schema.location(EntryKey(tree: key.tree, path: parent))
            try db.run("""
                UPDATE entries AS e SET logical = logical + ?, allocated = allocated + ?, files = files + ?
                WHERE \(location.predicate)
                """, [.int(delta.logical), .int(delta.allocated), .int(delta.files)] + location.values)
            next = parentPath(parent)
        }
    }

    func markGap(_ key: EntryKey) throws {
        try db.run("INSERT OR REPLACE INTO gaps VALUES (?, ?, ?)",
                   key.values + [.real(Date().addingTimeInterval(3_600).timeIntervalSince1970)])
    }

    @discardableResult
    func clearGap(_ key: EntryKey) throws -> Bool {
        try db.run("DELETE FROM gaps WHERE tree = ? AND path = ?", key.values)
        return db.changes > 0
    }

    func gaps(limit: Int64, dueBefore: Date) throws -> [EntryKey] {
        var result: [EntryKey] = []
        try db.query("SELECT tree, path FROM gaps WHERE retry_after <= ? ORDER BY retry_after LIMIT ?",
                     [.real(dueBefore.timeIntervalSince1970), .int(limit)]) { row in
            if let tree = VolumeTree(rawValue: sqlInt(row, 0)), let path = sqlText(row, 1) {
                result.append(EntryKey(tree: tree, path: path))
            }
        }
        return result
    }

    func auditPaths(after path: String, limit: Int64) throws -> [String] {
        var result: [String] = []
        let query = schema == .directoryReferences ? """
            SELECT p.path FROM parent_paths p CROSS JOIN entries e ON e.directory = p.id
            WHERE p.tree = 0 AND p.path > ? AND e.kind = 1 ORDER BY p.path LIMIT ?
            """ : "SELECT path FROM entries WHERE tree = 0 AND kind = 1 AND path > ? ORDER BY path LIMIT ?"
        try db.query(query, [.text(path), .int(limit)]) { row in
            if let path = sqlText(row, 0) { result.append(path) }
        }
        return result
    }

    func missingChildren(_ key: EntryKey) throws -> [String] {
        var result: [String] = []
        let children = schema.children(key)
        try db.query("""
            SELECT e.name FROM entries e WHERE \(children.predicate)
            AND NOT EXISTS (SELECT 1 FROM seen WHERE seen.name = e.name) LIMIT 256
            """, children.values) { row in
            if let name = sqlText(row, 0) { result.append(name) }
        }
        return result
    }

    func totals() throws -> Totals {
        var result = Totals()
        try db.query("SELECT COALESCE(sum(logical), 0), COALESCE(sum(allocated), 0), COALESCE(sum(files), 0) FROM entries WHERE parent IS NULL") {
            result = Totals(logical: sqlInt($0, 0), allocated: sqlInt($0, 1), files: sqlInt($0, 2))
        }
        return result
    }

    func recordSample(capacity: Int64, available: Int64, now: Date) throws {
        let interval: Int = 3_600
        let bucket = Int(now.timeIntervalSince1970) / interval * interval
        let totals = try totals()
        try db.run("INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?)",
                   [.int(Int64(bucket)), .int(capacity), .int(available), .int(totals.allocated)])
        try db.run("DELETE FROM samples WHERE date < ?", [.int(Int64(bucket - 90 * 24 * interval))])
    }
}

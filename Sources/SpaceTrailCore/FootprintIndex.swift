import Foundation

/// Persists one measurement per item and incremental totals for each ancestor.
final class FootprintIndex {
    static let tables = ["file_footprints", "folder_footprints", "folder_shares", "footprint_priority", "footprint_peers"]

    struct Change {
        let rowID: Int64
        let key: EntryKey
        let footprint: FileFootprint?
    }

    private struct Totals {
        var exclusive: Int64 = 0
        var shared: Int64 = 0
        var measured: Int64 = 0
        var incomplete: Int64 = 0
    }

    private struct Candidate {
        let rowID: Int64
        let key: EntryKey
        let inode: Int64
        let needsMeasurement: Bool
    }

    private struct Priority {
        let key: EntryKey
        let cursor: String
        let turn: Int64
    }

    private struct PeerJob {
        let tree: VolumeTree
        let identity: String
        let cursor: Int64
        let again: Bool
    }

    private let db: SQLiteConnection

    init(db: SQLiteConnection) { self.db = db }

    static func isAvailable(in db: SQLiteConnection) throws -> Bool {
        try db.integer("SELECT 1 FROM sqlite_schema WHERE name = 'folder_footprints'") == 1
    }

    static func read(_ entry: StorageEntry, from db: SQLiteConnection) throws -> PhysicalFootprint? {
        if !entry.isFolder {
            var result: PhysicalFootprint?
            try db.query("""
                SELECT f.exclusive, f.shared, f.incomplete
                FROM entries e JOIN file_footprints f ON f.entry_id = e.rowid WHERE e.tree = ? AND e.path = ?
                """, entry.id.values) {
                result = PhysicalFootprint(exclusiveBytes: sqlInt($0, 0), sharedBytes: sqlInt($0, 1),
                                           scannedFiles: 1, incomplete: sqlInt($0, 2) != 0)
            }
            return result
        }
        var exclusive: Int64 = 0
        var shared: Int64 = 0
        var count: Int64 = 0
        var incomplete = false
        try db.query("""
            SELECT f.exclusive, f.shared, f.measured, f.incomplete
            FROM entries e JOIN folder_footprints f ON f.entry_id = e.rowid WHERE e.tree = ? AND e.path = ?
            """, entry.id.values) {
            exclusive = sqlInt($0, 0)
            shared = sqlInt($0, 1)
            count = sqlInt($0, 2)
            incomplete = sqlInt($0, 3) > 0
        }
        guard count > 0 || entry.files == 0 else { return nil }
        if !incomplete, count >= entry.files {
            incomplete = try db.integer("SELECT 1 FROM gaps WHERE \(subtreeWhere) LIMIT 1", entry.id.subtreeValues) != 0
            if !incomplete {
                incomplete = try db.integer("SELECT 1 FROM limited_scopes WHERE \(subtreeWhere) LIMIT 1",
                                            entry.id.subtreeValues) != 0
            }
        }
        return PhysicalFootprint(exclusiveBytes: exclusive, sharedBytes: shared, scannedFiles: count,
                                 incomplete: incomplete || count < entry.files)
    }

    func createTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS file_footprints (
                entry_id INTEGER PRIMARY KEY, exclusive INTEGER NOT NULL, shared INTEGER NOT NULL,
                identity TEXT, incomplete INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS footprint_identity ON file_footprints(identity) WHERE identity IS NOT NULL;
            CREATE INDEX IF NOT EXISTS footprint_inode ON entries(tree, inode) WHERE kind = 0;
            CREATE TABLE IF NOT EXISTS folder_footprints (
                entry_id INTEGER PRIMARY KEY, exclusive INTEGER NOT NULL, shared INTEGER NOT NULL,
                measured INTEGER NOT NULL, incomplete INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS folder_footprint_size ON folder_footprints(exclusive + shared);
            CREATE TABLE IF NOT EXISTS folder_shares (
                folder_id INTEGER NOT NULL, identity TEXT NOT NULL, bytes INTEGER NOT NULL, copies INTEGER NOT NULL,
                PRIMARY KEY(folder_id, identity, bytes)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS footprint_priority (
                tree INTEGER NOT NULL, path TEXT NOT NULL, cursor TEXT NOT NULL, turn INTEGER NOT NULL,
                PRIMARY KEY(tree, path)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS footprint_peers (
                tree INTEGER NOT NULL, identity TEXT NOT NULL, cursor INTEGER NOT NULL, again INTEGER NOT NULL,
                PRIMARY KEY(tree, identity)
            ) WITHOUT ROWID;
            CREATE TRIGGER IF NOT EXISTS remove_footprint AFTER DELETE ON entries BEGIN
                DELETE FROM file_footprints WHERE entry_id = old.rowid AND old.kind <> 1;
                DELETE FROM folder_footprints WHERE entry_id = old.rowid AND old.kind = 1;
                DELETE FROM folder_shares WHERE folder_id = old.rowid AND old.kind = 1;
            END;
            """)
    }

    @discardableResult
    func update(_ key: EntryKey, footprint: FileFootprint, trackPeers: Bool) throws -> Bool {
        let id = try db.integer("SELECT rowid FROM entries WHERE tree = ? AND path = ? AND kind <> 1", key.values)
        guard id != 0 else { return false }
        return try apply([Change(rowID: id, key: key, footprint: footprint)], trackPeers: trackPeers)
    }

    func prioritize(_ folders: [StorageEntry]) throws {
        for (turn, folder) in folders.enumerated() {
            try db.run("INSERT OR IGNORE INTO footprint_priority VALUES (?, ?, ?, ?)",
                       folder.id.values + [.text(folder.id.path + "/"), .int(Int64(turn))])
        }
    }

    func fillPage(limit: Int, preferPriority: Bool,
                  measure: (EntryKey, Int64) -> FileFootprint) throws -> (advanced: Bool, changed: Bool) {
        let position = try db.text("SELECT value FROM meta WHERE key = 'footprintCursor'")
        var priority: Priority?
        if preferPriority || position == "complete" {
            try db.query("SELECT tree, path, cursor, turn FROM footprint_priority ORDER BY turn, tree, path LIMIT 1") {
                if let tree = VolumeTree(rawValue: sqlInt($0, 0)), let path = sqlText($0, 1), let cursor = sqlText($0, 2) {
                    priority = Priority(key: EntryKey(tree: tree, path: path), cursor: cursor, turn: sqlInt($0, 3))
                }
            }
        }
        if position == "complete", priority == nil { return (false, false) }
        let page: [Candidate]
        if let priority {
            page = try candidates(
                after: "e.tree = ? AND e.path > ? AND e.path < ? ORDER BY e.path",
                values: [.int(priority.key.tree.rawValue), .text(priority.cursor), .text(priority.key.path + "0")],
                limit: limit
            )
            if let last = page.last, page.count == limit {
                // Small round-robin pages let several important folders become useful together.
                let nextTurn = try db.integer("SELECT max(turn) FROM footprint_priority") + 1
                try db.run("UPDATE footprint_priority SET cursor = ?, turn = ? WHERE tree = ? AND path = ?",
                           [.text(last.key.path), .int(max(nextTurn, priority.turn + 1))] + priority.key.values)
            } else {
                try db.run("DELETE FROM footprint_priority WHERE tree = ? AND path = ?", priority.key.values)
            }
        } else {
            let cursor = position.flatMap(Int64.init) ?? 0
            page = try candidates(after: "e.rowid > ? ORDER BY e.rowid", values: [.int(cursor)], limit: limit)
            let checkpoint = page.count == limit ? String(page.last?.rowID ?? cursor) : "complete"
            try db.run("INSERT OR REPLACE INTO meta VALUES ('footprintCursor', ?)", [.text(checkpoint)])
        }
        let changes = page.filter(\.needsMeasurement).map { candidate in
            Change(rowID: candidate.rowID, key: candidate.key, footprint: measure(candidate.key, candidate.inode))
        }
        return (true, try apply(changes))
    }

    private func candidates(after scope: String, values: [SQLValue], limit: Int) throws -> [Candidate] {
        var result: [Candidate] = []
        try db.query("""
            SELECT e.rowid, e.tree, e.path, e.inode, e.kind <> 1 AND f.entry_id IS NULL
            FROM entries e LEFT JOIN file_footprints f ON f.entry_id = e.rowid
            WHERE \(scope) LIMIT ?
            """, values + [.int(Int64(limit))]) {
            if let tree = VolumeTree(rawValue: sqlInt($0, 1)), let path = sqlText($0, 2) {
                result.append(Candidate(rowID: sqlInt($0, 0), key: EntryKey(tree: tree, path: path),
                                        inode: sqlInt($0, 3), needsMeasurement: sqlInt($0, 4) != 0))
            }
        }
        return result
    }

    func hasPeerJobs() throws -> Bool {
        try db.integer("SELECT 1 FROM footprint_peers LIMIT 1") != 0
    }

    func nextPeerPage(limit: Int) throws -> [EntryKey]? {
        var result: [EntryKey] = []
        var advanced = false
        for _ in 0..<32 {
            guard result.count < limit, let job = try nextPeerJob() else { break }
            advanced = true
            let key: [SQLValue] = [.int(job.tree.rawValue), .text(job.identity)]
            let source = job.identity.split(separator: ":").last.flatMap { UInt64($0) }
            let remaining = limit - result.count
            var last = job.cursor
            let start = result.count
            // A clone ID can match the source inode. Indexed family members cover
            // survivors of a deleted source and hard links in other directories.
            try db.query("""
                SELECT e.rowid, e.path FROM entries e
                WHERE e.kind = 0 AND e.tree = ? AND e.inode = ? AND e.rowid > ?
                UNION
                SELECT e.rowid, e.path FROM file_footprints f JOIN entries e ON e.rowid = f.entry_id
                WHERE f.identity = ? AND f.entry_id > ? AND e.tree = ?
                ORDER BY 1 LIMIT ?
                """, [
                    .int(job.tree.rawValue), source.map { .int(Int64(bitPattern: $0)) } ?? .null, .int(job.cursor),
                    .text(job.identity), .int(job.cursor), .int(job.tree.rawValue), .int(Int64(remaining))
                ]) {
                last = sqlInt($0, 0)
                if let path = sqlText($0, 1) { result.append(EntryKey(tree: job.tree, path: path)) }
            }
            if result.count - start == remaining {
                try db.run("UPDATE footprint_peers SET cursor = ? WHERE tree = ? AND identity = ?", [.int(last)] + key)
            } else if job.again {
                try db.run("UPDATE footprint_peers SET cursor = 0, again = 0 WHERE tree = ? AND identity = ?", key)
            } else {
                try db.run("DELETE FROM footprint_peers WHERE tree = ? AND identity = ?", key)
            }
        }
        return advanced ? result : nil
    }

    private func nextPeerJob() throws -> PeerJob? {
        var job: PeerJob?
        try db.query("SELECT tree, identity, cursor, again FROM footprint_peers ORDER BY tree, identity LIMIT 1") {
            if let tree = VolumeTree(rawValue: sqlInt($0, 0)), let identity = sqlText($0, 1) {
                job = PeerJob(tree: tree, identity: identity, cursor: sqlInt($0, 2), again: sqlInt($0, 3) != 0)
            }
        }
        return job
    }

    @discardableResult
    func apply(_ changes: [Change], trackPeers: Bool = false) throws -> Bool {
        var ancestorCache: [EntryKey: [Int64]] = [:]
        var totals: [Int64: Totals] = [:]
        var changed = false
        for change in changes {
            let previous = try fact(change.rowID)
            guard previous != change.footprint else { continue }
            let folders = try ancestors(of: change.key, cachedIn: &ancestorCache)
            for folder in folders {
                var delta = totals[folder, default: Totals()]
                if let previous { try add(previous, to: folder, sign: -1, delta: &delta) }
                if let footprint = change.footprint { try add(footprint, to: folder, sign: 1, delta: &delta) }
                totals[folder] = delta
            }
            if let footprint = change.footprint {
                try db.run("INSERT OR REPLACE INTO file_footprints VALUES (?, ?, ?, ?, ?)", [
                    .int(change.rowID), .int(footprint.exclusive), .int(footprint.shared),
                    footprint.identity.map(SQLValue.text) ?? .null, .int(footprint.incomplete ? 1 : 0)
                ])
            } else {
                try db.run("DELETE FROM file_footprints WHERE entry_id = ?", [.int(change.rowID)])
            }
            if trackPeers {
                for identity in Set([previous?.identity, change.footprint?.identity].compactMap { $0 }) {
                    try db.run("""
                        INSERT INTO footprint_peers VALUES (?, ?, 0, 0)
                        ON CONFLICT(tree, identity) DO UPDATE SET again = max(again, cursor > 0)
                        """, [.int(change.key.tree.rawValue), .text(identity)])
                }
            }
            changed = true
        }
        for (folder, delta) in totals {
            guard delta.exclusive != 0 || delta.shared != 0 || delta.measured != 0 || delta.incomplete != 0 else { continue }
            try db.run("""
                INSERT INTO folder_footprints VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(entry_id) DO UPDATE SET exclusive = exclusive + excluded.exclusive,
                    shared = shared + excluded.shared, measured = measured + excluded.measured,
                    incomplete = incomplete + excluded.incomplete
                """, [.int(folder), .int(delta.exclusive), .int(delta.shared), .int(delta.measured), .int(delta.incomplete)])
        }
        return changed
    }

    private func fact(_ id: Int64) throws -> FileFootprint? {
        var result: FileFootprint?
        try db.query("SELECT exclusive, shared, identity, incomplete FROM file_footprints WHERE entry_id = ?", [.int(id)]) {
            result = FileFootprint(exclusive: sqlInt($0, 0), shared: sqlInt($0, 1),
                                   identity: sqlText($0, 2), incomplete: sqlInt($0, 3) != 0)
        }
        return result
    }

    private func ancestors(of key: EntryKey, cachedIn cache: inout [EntryKey: [Int64]]) throws -> [Int64] {
        guard let parent = parentPath(key.path), isWithin(parent, key.tree.root) else { return [] }
        let parentKey = EntryKey(tree: key.tree, path: parent)
        if let ids = cache[parentKey] { return ids }
        var ids = try ancestors(of: parentKey, cachedIn: &cache)
        let id = try db.integer("SELECT rowid FROM entries WHERE tree = ? AND path = ? AND kind = 1", parentKey.values)
        if id != 0 { ids.append(id) }
        cache[parentKey] = ids
        return ids
    }

    private func add(_ footprint: FileFootprint, to folder: Int64, sign: Int64, delta: inout Totals) throws {
        delta.exclusive += sign * footprint.exclusive
        delta.measured += sign
        if footprint.incomplete { delta.incomplete += sign }
        guard let identity = footprint.identity, footprint.shared > 0 else { return }
        let group: [SQLValue] = [.int(folder), .text(identity)]
        let size = group + [.int(footprint.shared)]
        let before = try sharedAmount(group)
        if sign > 0 {
            try db.run("""
                INSERT INTO folder_shares VALUES (?, ?, ?, 1)
                ON CONFLICT(folder_id, identity, bytes) DO UPDATE SET copies = copies + 1
                """, size)
        } else {
            try db.run("UPDATE folder_shares SET copies = copies - 1 WHERE folder_id = ? AND identity = ? AND bytes = ?", size)
            try db.run("DELETE FROM folder_shares WHERE folder_id = ? AND identity = ? AND bytes = ? AND copies = 0", size)
        }
        let after = try sharedAmount(group)
        delta.shared += after.bytes - before.bytes
        delta.incomplete += after.incomplete - before.incomplete
    }

    private func sharedAmount(_ group: [SQLValue]) throws -> (bytes: Int64, incomplete: Int64) {
        // A shared extent group counts once in each folder, including ancestors spanning several branches.
        var sizes: [Int64] = []
        try db.query("SELECT bytes FROM folder_shares WHERE folder_id = ? AND identity = ? ORDER BY bytes DESC LIMIT 2", group) {
            sizes.append(sqlInt($0, 0))
        }
        return (sizes.first ?? 0, sizes.count > 1 ? 1 : 0)
    }
}

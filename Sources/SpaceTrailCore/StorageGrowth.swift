import Foundation

/// Net allocation changes observed by the broker, with one row per file and hour.
final class StorageGrowthIndex {
    private static let startKey = "growthStartedAt"
    private static let trimmedKey = "growthTrimmedThrough"
    private let db: SQLiteConnection
    private let schema: IndexSchema
    private var startedAt: Double?

    init(db: SQLiteConnection, schema: IndexSchema) {
        self.db = db
        self.schema = schema
    }

    func createTables() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS storage_growth (
                id INTEGER PRIMARY KEY, inode INTEGER NOT NULL, created REAL NOT NULL,
                bucket INTEGER NOT NULL, entry_id INTEGER NOT NULL, delta INTEGER NOT NULL,
                allocated INTEGER NOT NULL, observed REAL NOT NULL, UNIQUE(inode, created, bucket)
            );
            CREATE INDEX IF NOT EXISTS growth_by_hour ON storage_growth(bucket);
            CREATE TRIGGER IF NOT EXISTS bound_growth AFTER INSERT ON storage_growth
            WHEN new.id >= 65536 AND new.id % 512 = 0 BEGIN
                INSERT INTO meta(key, value)
                SELECT '\(Self.trimmedKey)', MAX(bucket) + 3600 FROM storage_growth
                WHERE id <= new.id - 65536 HAVING COUNT(*) > 0
                ON CONFLICT(key) DO UPDATE SET value = MAX(CAST(meta.value AS REAL), CAST(excluded.value AS REAL));
                DELETE FROM storage_growth WHERE id <= new.id - 65536;
            END;
            """)
    }

    func start(at now: Date = .now) throws {
        let time = now.timeIntervalSince1970
        try db.run("INSERT OR IGNORE INTO meta VALUES (?, ?)", [.text(Self.startKey), .text(String(time))])
        startedAt = try db.text("SELECT value FROM meta WHERE key = ?", [.text(Self.startKey)]).flatMap(Double.init)
    }

    func record(_ file: StorageEntry, replacing previous: StorageEntry?, footprint: FileFootprint,
                at now: Date = .now) throws {
        guard let startedAt, file.id.tree == .data, file.kind == .file, file.links == 1 else { return }
        let birth = file.created.timeIntervalSince1970
        let sameFile = previous?.kind == .file && previous?.inode == file.inode && previous?.created == file.created
        if sameFile, previous?.allocated == file.allocated { return }

        let identity: [SQLValue] = [.int(file.inode), .real(birth)]
        var last: (id: Int64, allocated: Int64)?
        try db.query("""
            SELECT id, allocated FROM storage_growth WHERE inode = ? AND created = ? ORDER BY bucket DESC LIMIT 1
            """, identity) { last = (sqlInt($0, 0), sqlInt($0, 1)) }
        if !sameFile, last == nil, footprint.shared > 0, footprint.shared == file.allocated { return }

        // An older file discovered after a permission change could have been present all along.
        // An already tracked inode arriving at a different path is a move.
        let before: Int64
        if sameFile { before = previous?.allocated ?? 0 }
        else if let last { before = last.allocated }
        else if birth >= startedAt, previous?.kind == .file { before = previous?.allocated ?? 0 }
        else if birth >= startedAt { before = 0 }
        else { return }

        let change = file.allocated - before
        guard change != 0 || (!sameFile && last != nil) else { return }
        let location = schema.location(file.id)
        let entryID = try db.integer("SELECT e.rowid FROM entries e WHERE \(location.predicate)", location.values)
        guard entryID != 0 else { return }
        if change == 0, let last {
            try db.run("UPDATE storage_growth SET entry_id = ? WHERE id = ?", [.int(entryID), .int(last.id)])
            return
        }
        let time = now.timeIntervalSince1970
        try db.run("""
            INSERT INTO storage_growth (inode, created, bucket, entry_id, delta, allocated, observed)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(inode, created, bucket) DO UPDATE SET
                entry_id = excluded.entry_id, delta = storage_growth.delta + excluded.delta,
                allocated = excluded.allocated, observed = excluded.observed
            """, identity + [.int(Self.bucket(time)), .int(entryID), .int(change), .int(file.allocated), .real(time)])
    }

    func prune(at now: Date) throws {
        let cutoff = Self.bucket(now.timeIntervalSince1970) - 90 * 86_400
        try db.run("DELETE FROM storage_growth WHERE bucket < ?", [.int(cutoff)])
    }

    static func read(from db: SQLiteConnection, schema: IndexSchema, days: Int) throws -> RecentGrowth {
        let metadata = try db.text("SELECT value FROM meta WHERE key = ?", [.text(startKey)])
        guard let raw = metadata.flatMap(Double.init) else {
            return RecentGrowth(since: nil, files: [], folders: [])
        }
        let trimmed = try db.text("SELECT value FROM meta WHERE key = ?", [.text(trimmedKey)]).flatMap(Double.init) ?? 0
        let since = max(raw, trimmed)
        let cutoff = bucket(Date().timeIntervalSince1970) - Int64(days) * 86_400
        var files: [FileGrowth] = []
        var folders: [FolderGrowth] = []
        let sameFolder: String
        switch schema {
        case .fullPaths: sameFolder = "f.path = totals.parent"
        case .compactParents: sameFolder = "f.path = (SELECT path FROM parent_paths WHERE id = totals.parent)"
        case .directoryReferences: sameFolder = "f.directory = totals.parent"
        }
        // Start with the bounded growth history. Joining entries first can scan
        // the entire file index on versions of SQLite that choose footprint_inode.
        try db.query("""
            WITH changes AS (
                SELECT inode, created, MAX(bucket) AS latest, SUM(delta) AS growth
                FROM storage_growth WHERE bucket >= ? GROUP BY inode, created HAVING SUM(delta) > 0
            ), matched AS MATERIALIZED (
                SELECT e.rowid AS entry_id, e.parent, c.growth, g.observed
                FROM changes c CROSS JOIN storage_growth g
                    ON g.inode = c.inode AND g.created = c.created AND g.bucket = c.latest
                CROSS JOIN entries e NOT INDEXED ON e.rowid = g.entry_id AND e.tree = 0 AND e.kind = 0
                    AND e.inode = c.inode AND e.created = c.created AND e.links = 1
            ), largest_files AS (
                SELECT entry_id, growth, observed, 0 AS file_count FROM matched
                ORDER BY growth DESC, observed DESC, entry_id DESC LIMIT 8
            ), totals AS (
                SELECT parent, SUM(growth) AS growth, MAX(observed) AS observed, COUNT(*) AS file_count
                FROM matched WHERE parent IS NOT NULL GROUP BY parent
            ), largest_folders AS (
                SELECT f.rowid AS entry_id, totals.growth, totals.observed, totals.file_count
                FROM totals CROSS JOIN entries f ON f.tree = 0 AND f.kind = 1 AND \(sameFolder)
                ORDER BY totals.growth DESC, totals.observed DESC, f.rowid DESC LIMIT 8
            ), ranked AS (
                SELECT * FROM largest_files UNION ALL SELECT * FROM largest_folders
            )
            SELECT \(schema.columns()), r.growth, r.observed, r.file_count
            FROM ranked r JOIN entries e ON e.rowid = r.entry_id
            ORDER BY r.growth DESC, r.observed DESC, e.rowid DESC
            """, [.int(cutoff)]) { row in
                let entry = indexEntry(row)
                let bytes = sqlInt(row, 15)
                let count = sqlInt(row, 17)
                if count > 0 {
                    folders.append(FolderGrowth(entry: entry, bytes: bytes, fileCount: count))
                } else {
                    files.append(FileGrowth(entry: entry, bytes: bytes,
                                            observed: Date(timeIntervalSince1970: sqlReal(row, 16))))
                }
            }
        return RecentGrowth(since: Date(timeIntervalSince1970: since), files: files, folders: folders)
    }

    private static func bucket(_ time: Double) -> Int64 {
        Int64(floor(time / 3_600)) * 3_600
    }
}

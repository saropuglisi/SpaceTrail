import Darwin
import Foundation
import IOKit.ps
import SQLite3

// Readers keep this shared lock until SQLite closes the connection. Only the
// brief journal cleanup and file replacement need exclusive access.
final class IndexFileLock {
    private let fd: Int32

    init(support: URL, mode: Int32) throws {
        let path = support.appendingPathComponent("index.lock").path
        let handle = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard handle >= 0 else { throw FilesystemFailure(path: path, code: errno) }
        guard flock(handle, mode) == 0 else {
            let code = errno
            close(handle)
            throw FilesystemFailure(path: path, code: code)
        }
        fd = handle
    }

    deinit { close(fd) }
}

enum IndexMigration {
    private static let lastAttempt = "indexMigrationV2Attempt"

    static func removeInterruptedCopy(in support: URL) throws {
        for staging in [stagingDirectory(in: support),
                        support.appendingPathComponent(".index-migration-v1", isDirectory: true)] {
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
        }
    }

    static func isEligible(_ db: SQLiteConnection, in support: URL) throws -> Bool {
        guard try IndexSchema.read(from: db) != .current, allowsMaintenance,
              try db.integer("SELECT count(*) FROM sqlite_schema WHERE name = 'meta'") == 1,
              try db.text("SELECT value FROM meta WHERE key = 'baseline'") == "1" else { return false }
        let attempt = try db.text("SELECT value FROM meta WHERE key = ?", [.text(lastAttempt)]).flatMap(Double.init)
        if let attempt, Date().timeIntervalSince1970 - attempt < 6 * 3_600 { return false }

        let pagesInUse = try db.integer("PRAGMA page_count") - db.integer("PRAGMA freelist_count")
        let pageSize = try db.integer("PRAGMA page_size")
        return try mountInfo(support.path).available >= max(0, pagesInUse) * pageSize + IndexWriter.reserve
    }

    static func migrateIfEligible(in support: URL, willCopy: () -> Void) throws {
        let original = SpaceTrailPaths.database(in: support)
        guard FileManager.default.fileExists(atPath: original.path), try startAttempt(original, in: support) else { return }
        willCopy()
        // Checkpoint the source before opening it read-only under ATTACH. A WAL
        // database can have no sidecars after its last writer exits.
        try withExtendedLifetime(IndexFileLock(support: support, mode: LOCK_EX)) {
            try closeJournal(at: original)
        }

        let staging = stagingDirectory(in: support)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try buildCopy(of: original, in: staging)

        let copy = SpaceTrailPaths.database(in: staging)
        let lock = try IndexFileLock(support: support, mode: LOCK_EX)
        try withExtendedLifetime(lock) {
            try closeJournal(at: original)
            guard rename(copy.path, original.path) == 0 else {
                throw FilesystemFailure(path: original.path, code: errno)
            }
        }
    }

    private static var allowsMaintenance: Bool {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        // Fixture runs borrow the same migration path regardless of the host battery.
        if SpaceTrailPaths.fixtureRoot != nil { return true }
        guard let sources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let power = IOPSGetProvidingPowerSourceType(sources)?.takeUnretainedValue() else { return false }
        return (power as String) == kIOPSACPowerValue
    }

    private static func startAttempt(_ original: URL, in support: URL) throws -> Bool {
        let db = try SQLiteConnection(original, readOnly: false)
        guard try isEligible(db, in: support) else { return false }
        try db.run("INSERT OR REPLACE INTO meta VALUES (?, ?)",
                   [.text(lastAttempt), .text(String(Date().timeIntervalSince1970))])
        return true
    }

    private static func buildCopy(of original: URL, in staging: URL) throws {
        let writer = try IndexWriter(support: staging, deferIndexes: true)
        let db = writer.db
        guard var source = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            throw FilesystemFailure(path: original.path, code: EINVAL)
        }
        source.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = source.url?.absoluteString else { throw FilesystemFailure(path: original.path, code: EINVAL) }
        try db.run("ATTACH DATABASE ? AS legacy", [.text(uri)])
        try db.run("PRAGMA synchronous = FULL")
        let sourceVersion = try db.integer("PRAGMA legacy.user_version")

        // Copy the broker's history and cursors verbatim, including any unfinished repairs.
        try db.transaction("BEGIN IMMEDIATE") {
            for table in ["meta", "samples", "gaps", "limited_scopes", "pending_scan", "pending_repair"] {
                try db.run("INSERT INTO main.\(table) SELECT * FROM legacy.\(table)")
            }
            try db.run("DELETE FROM main.meta WHERE key IN (?, 'searchCursor', 'indexMigrationAttempt')", [.text(lastAttempt)])
            if sourceVersion == IndexSchema.compactParents.rawValue {
                try db.run("INSERT INTO main.parent_paths SELECT * FROM legacy.parent_paths")
            } else {
                try db.run("""
                    INSERT OR IGNORE INTO main.parent_paths(tree, path)
                    SELECT tree, parent FROM legacy.entries WHERE parent IS NOT NULL
                    """)
            }
            try db.run("""
                INSERT OR IGNORE INTO main.parent_paths(tree, path)
                SELECT tree, path FROM legacy.entries WHERE kind = 1
                UNION ALL SELECT tree, path FROM legacy.entries WHERE parent IS NULL AND kind <> 1
                """)
        }

        let parent = sourceVersion == IndexSchema.compactParents.rawValue ? "p.id = e.parent" : "p.tree = e.tree AND p.path = e.parent"
        var cursor: Int64 = 0
        var copied: Int64 = 0
        while let range = try nextBatch(db, after: cursor) {
            guard allowsMaintenance else { throw CancellationError() }
            try writer.checkDiskSpace()
            let bounds: [SQLValue] = [.int(cursor), .int(range.end)]
            try db.transaction("BEGIN IMMEDIATE") {
                try db.run("""
                    INSERT INTO main.entries(rowid, tree, directory, \(entryMetadataColumns))
                    SELECT e.rowid, e.tree, d.id, p.id, e.name, e.name_key, e.kind,
                           e.logical, e.allocated, e.files, e.modified, e.created, e.inode, e.mode, e.links
                    FROM legacy.entries e
                    LEFT JOIN main.parent_paths p ON \(parent)
                    LEFT JOIN main.parent_paths d
                        ON (e.kind = 1 OR e.parent IS NULL) AND d.tree = e.tree AND d.path = e.path
                    WHERE e.rowid > ? AND e.rowid <= ?
                        AND (e.parent IS NULL OR (p.tree = e.tree AND e.path = (\(IndexSchema.childPath))))
                        AND ((e.parent IS NOT NULL AND e.kind <> 1) OR d.id IS NOT NULL)
                    """, bounds)
                guard db.changes == range.count else { throw invalidCopy() }
            }
            copied += range.count
            cursor = range.end
        }
        guard copied == (try db.integer("SELECT count(*) FROM legacy.entries")) else { throw invalidCopy() }
        if try db.integer("SELECT count(*) FROM legacy.sqlite_schema WHERE name = 'storage_growth'") == 1 {
            try db.run("""
                INSERT INTO main.storage_growth(inode, created, bucket, entry_id, delta, allocated, observed)
                SELECT inode, created, bucket, entry_id, delta, allocated, observed FROM legacy.storage_growth ORDER BY id
                """)
        }
        // The staging copy preserves entry rowids, including those referenced by measurements.
        for table in FootprintIndex.tables {
            if try db.integer("SELECT count(*) FROM legacy.sqlite_schema WHERE name = ?", [.text(table)]) == 1 {
                try writer.checkDiskSpace()
                try db.run("INSERT INTO main.\(table) SELECT * FROM legacy.\(table)")
            }
        }
        // Priority walks now visit siblings together. Restart only these cursors;
        // the saved rowid cursor and all completed measurements still apply.
        try db.run("UPDATE footprint_priority SET cursor = CASE WHEN path = '/' THEN '/' ELSE path || '/' END")
        try db.run("DETACH DATABASE legacy")
        try writer.checkDiskSpace()
        try writer.createIndexes()
        try writer.createSearch()
        try db.run("INSERT INTO name_fts(name_fts) VALUES ('rebuild')")
        try db.run("INSERT INTO name_fts(name_fts) VALUES ('optimize')")
        guard try db.text("PRAGMA quick_check(1)") == "ok" else { throw invalidCopy() }
        try db.run("INSERT INTO name_fts(name_fts, rank) VALUES ('integrity-check', 1)")
        try writer.set("searchComplete", "1")
        guard try db.text("PRAGMA journal_mode = DELETE") == "delete" else { throw invalidCopy() }
    }

    private static func nextBatch(_ db: SQLiteConnection, after cursor: Int64) throws -> (count: Int64, end: Int64)? {
        var result: (count: Int64, end: Int64)?
        try db.query("""
            SELECT count(*), max(rowid)
            FROM (SELECT rowid FROM legacy.entries WHERE rowid > ? ORDER BY rowid LIMIT 8_192)
            """, [.int(cursor)]) { row in
            let count = sqlInt(row, 0)
            if count > 0 { result = (count, sqlInt(row, 1)) }
        }
        return result
    }

    private static func closeJournal(at url: URL) throws {
        let db = try SQLiteConnection(url, readOnly: false)
        guard try db.text("PRAGMA journal_mode = DELETE") == "delete" else {
            throw SQLiteFailure(code: SQLITE_BUSY, operation: "compaction", message: "The index is still in use.")
        }
    }

    private static func invalidCopy() -> SQLiteFailure {
        SQLiteFailure(code: SQLITE_CORRUPT, operation: "compaction", message: "The index copy failed verification.")
    }

    private static func stagingDirectory(in support: URL) -> URL {
        support.appendingPathComponent(".index-migration-v2", isDirectory: true)
    }
}

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
    private static let lastAttempt = "indexMigrationAttempt"

    static func removeInterruptedCopy(in support: URL) throws {
        let staging = stagingDirectory(in: support)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
    }

    static func isEligible(_ db: SQLiteConnection, in support: URL) throws -> Bool {
        guard try db.integer("PRAGMA user_version") == 0, allowsMaintenance,
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
        let writer = try IndexWriter(support: staging)
        let db = writer.db
        guard var source = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            throw FilesystemFailure(path: original.path, code: EINVAL)
        }
        source.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = source.url?.absoluteString else { throw FilesystemFailure(path: original.path, code: EINVAL) }
        try db.run("ATTACH DATABASE ? AS legacy", [.text(uri)])
        try db.run("PRAGMA synchronous = FULL")

        // Copy the broker's history and cursors verbatim, including any unfinished repairs.
        try db.transaction("BEGIN IMMEDIATE") {
            for table in ["meta", "samples", "gaps", "limited_scopes", "pending_scan", "pending_repair"] {
                try db.run("INSERT INTO main.\(table) SELECT * FROM legacy.\(table)")
            }
            try db.run("DELETE FROM main.meta WHERE key IN (?, 'searchCursor')", [.text(lastAttempt)])
            try db.run("INSERT OR REPLACE INTO main.meta VALUES ('searchComplete', '1')")
        }

        var cursor: Int64 = 0
        var copied: Int64 = 0
        while let range = try nextBatch(db, after: cursor) {
            guard allowsMaintenance else { throw CancellationError() }
            try writer.checkDiskSpace()
            let bounds: [SQLValue] = [.int(cursor), .int(range.end)]
            try db.transaction("BEGIN IMMEDIATE") {
                try db.run("""
                    INSERT OR IGNORE INTO parent_paths(tree, path)
                    SELECT tree, parent FROM legacy.entries
                    WHERE rowid > ? AND rowid <= ? AND parent IS NOT NULL
                    """, bounds)
                try db.run("""
                    INSERT INTO main.entries(rowid, \(entryColumns))
                    SELECT e.rowid, e.tree, e.path, p.id, e.name, e.name_key, e.kind,
                           e.logical, e.allocated, e.files, e.modified, e.created, e.inode, e.mode, e.links
                    FROM legacy.entries e LEFT JOIN parent_paths p ON p.tree = e.tree AND p.path = e.parent
                    WHERE e.rowid > ? AND e.rowid <= ? AND (e.parent IS NULL OR p.id IS NOT NULL)
                    """, bounds)
                guard db.changes == range.count else { throw invalidCopy() }
            }
            copied += range.count
            cursor = range.end
        }
        guard copied == (try db.integer("SELECT count(*) FROM legacy.entries")) else { throw invalidCopy() }
        // The staging copy preserves entry rowids, including those referenced by measurements.
        for table in FootprintIndex.tables {
            if try db.integer("SELECT count(*) FROM legacy.sqlite_schema WHERE name = ?", [.text(table)]) == 1 {
                try db.run("INSERT INTO main.\(table) SELECT * FROM legacy.\(table)")
            }
        }
        try db.run("DETACH DATABASE legacy")
        guard try db.text("PRAGMA quick_check(1)") == "ok" else { throw invalidCopy() }
        try db.run("INSERT INTO name_fts(name_fts, rank) VALUES ('integrity-check', 1)")
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
        support.appendingPathComponent(".index-migration-v1", isDirectory: true)
    }
}

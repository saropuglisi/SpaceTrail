import Darwin
import Foundation

public struct IndexReader: Sendable {
    public let support: URL

    public init(support: URL = SpaceTrailPaths.support) {
        self.support = support
    }

    public func revision() throws -> String? {
        guard let db = try database() else { return nil }
        return try meta("revision", db: db)
    }

    public func dashboard(since previous: String?, includeDetails: Bool) throws -> (revision: String?, overview: Overview?) {
        guard let db = try database() else { return (nil, nil) }
        db.checkCancellation()
        return try db.transaction("BEGIN") {
            let revision = try meta("revision", db: db)
            guard let revision, revision != previous else { return (revision, nil) }
            return (revision, try overview(in: db, includeDetails: includeDetails))
        }
    }

    public func page(scope: EntryScope, sort: EntrySort, ascending: Bool, search: String,
                     offset: Int, limit: Int, filters: SearchFilters = SearchFilters()) throws -> EntryPage {
        guard let db = try database() else { return EntryPage(rows: [], hasMore: false) }
        db.checkCancellation()
        return try db.transaction("BEGIN") {
            try page(db: db, scope: scope, sort: sort, ascending: ascending,
                     search: search, offset: offset, limit: limit, filters: filters)
        }
    }

    public func mapPage(in folder: EntryKey, limit: Int) throws -> MapPage {
        guard let db = try database() else { return MapPage(contents: EntryPage(rows: [], hasMore: false), previews: [:]) }
        db.checkCancellation()
        return try db.transaction("BEGIN") {
            let contents = try mapChildren(of: folder, in: db, limit: limit)
            var previews: [EntryKey: [StorageEntry]] = [:]
            for parent in contents.rows.lazy.filter({ $0.isFolder && ($0.footprint?.bytes ?? 0) > 0 }).prefix(8) {
                try Task.checkCancellation()
                let children = try mapChildren(of: parent.id, in: db, limit: 8).rows
                previews[parent.id] = children.filter { ($0.isFolder ? $0.footprint?.bytes ?? 0 : $0.allocated) > 0 }
            }
            return MapPage(contents: contents, previews: previews)
        }
    }

    private func mapChildren(of folder: EntryKey, in db: SQLiteConnection, limit: Int) throws -> EntryPage {
        try page(db: db, scope: .children(folder), sort: .allocated, ascending: false,
                 search: "", offset: 0, limit: limit, rankMeasuredFoldersOnly: true)
    }

    private func page(db: SQLiteConnection, scope: EntryScope, sort: EntrySort, ascending: Bool, search: String,
                      offset: Int, limit: Int, rankMeasuredFoldersOnly: Bool = false,
                      filters: SearchFilters = SearchFilters()) throws -> EntryPage {
        let measured = try FootprintIndex.isAvailable(in: db)
        if case .search = scope {
            return try searchPage(db: db, text: search, sort: sort, ascending: ascending,
                                  offset: offset, limit: limit, measured: measured, filters: filters)
        }
        let predicate: String
        var values: [SQLValue]
        let visibility = try visibleRows(in: db)
        switch scope {
        case .search:
            return EntryPage(rows: [], hasMore: false)
        case .files:
            predicate = "kind <> 1" + visibility
            values = []
        case .children(let key):
            if key.tree == .system && !visibility.isEmpty { return EntryPage(rows: [], hasMore: false) }
            let compact = try db.integer("PRAGMA user_version") == IndexWriter.schemaVersion
            predicate = IndexWriter.childrenWhere(compact: compact)
            values = IndexWriter.childrenValues(key, compact: compact)
        }
        let term = foldedName(search.trimmingCharacters(in: .whitespacesAndNewlines))
        let filter = term.isEmpty ? "" : " AND instr(name_key, ?) > 0"
        if !term.isEmpty { values.append(.text(term)) }
        let column = sortColumn(sort, entries: "entries", mixed: scope != .files, measured: measured,
                                rankMeasuredFoldersOnly: rankMeasuredFoldersOnly)
        let direction = ascending ? "ASC" : "DESC"
        let count = min(max(1, limit), 500)
        values += [.int(Int64(count + 1)), .int(Int64(max(0, offset)))]
        var rows: [StorageEntry] = []
        try db.query("""
            SELECT \(entryColumns) FROM entries WHERE \(predicate)\(filter)
            ORDER BY \(column) \(direction), rowid \(direction) LIMIT ? OFFSET ?
            """, values) { rows.append(indexEntry($0)) }
        return EntryPage(rows: try withFootprints(rows.prefix(count), in: db, measured: measured), hasMore: rows.count > count)
    }

    private func searchPage(db: SQLiteConnection, text: String, sort: EntrySort, ascending: Bool,
                            offset: Int, limit: Int, measured: Bool, filters: SearchFilters) throws -> EntryPage {
        let folded = foldedName(String(text.prefix(512)))
        let tokens = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return EntryPage(rows: [], hasMore: false) }
        let words = filters.similar ? tokens : [tokens.joined(separator: " ")]
        guard let first = words.first else { return EntryPage(rows: [], hasMore: false) }
        guard try meta("searchComplete", db: db) == "1" else { return EntryPage(rows: [], hasMore: false) }

        // FTS stores only trigram membership. Verify the full terms against the original name.
        var grams = Set<String>()
        for word in words {
            let letters = Array(word.unicodeScalars)
            guard letters.count >= 3 else { continue }
            for index in 0...(letters.count - 3) {
                grams.insert(String(String.UnicodeScalarView(letters[index..<(index + 3)])))
            }
        }
        var conditions = ["e.parent IS NOT NULL"]
        switch filters.kind {
        case .all: break
        case .files: conditions.append("e.kind <> 1")
        case .folders: conditions.append("e.kind = 1")
        }
        if try !visibleRows(in: db).isEmpty { conditions.append("e.tree = 0") }
        let basePredicate = conditions.joined(separator: " AND ")
        let match = grams.sorted().map(ftsTerm).joined(separator: " AND ")
        let wordValues = words.map(SQLValue.text)
        let direction = ascending ? "ASC" : "DESC"
        let column = sortColumn(sort, entries: "e", mixed: true, measured: measured)
        let count = min(max(1, limit), 500)
        let bounds: [SQLValue] = [.int(Int64(count + 1)), .int(Int64(max(0, offset)))]
        let columns = entryColumns.split(separator: " ").map { "e." + $0 }.joined(separator: " ")
        var rows: [StorageEntry] = []
        if !match.isEmpty, sort == .name, offset <= count * 2,
           try db.integer("SELECT count(*) FROM (SELECT 1 FROM name_fts WHERE name_fts MATCH ? LIMIT 8192)",
                          [.text(match)]) == 8192 {
            // A broad match can touch hundreds of thousands of rows for name sorting.
            // Accept a bounded walk of the name index only if it produces a full page
            // plus a successor, so the order and the availability of later pages are exact.
            let terms = words.map { _ in "instr(name_key, ?) > 0" }.joined(separator: " AND ")
            try db.query("""
                WITH names AS MATERIALIZED (
                    SELECT rowid AS entry_id, name_key FROM entries INDEXED BY entry_name
                    ORDER BY name_key \(direction), rowid \(direction) LIMIT 65536
                ), matches AS MATERIALIZED (
                    SELECT entry_id, name_key FROM names WHERE \(terms)
                )
                SELECT \(columns) FROM matches m CROSS JOIN entries e ON e.rowid = m.entry_id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY m.name_key \(direction), m.entry_id \(direction) LIMIT ? OFFSET ?
                """, wordValues + bounds) { rows.append(indexEntry($0)) }
            if rows.count > count {
                return EntryPage(rows: try withFootprints(rows.prefix(count), in: db, measured: measured), hasMore: true)
            }
            rows.removeAll(keepingCapacity: true)
        }

        let source: String
        var values: [SQLValue]
        if match.isEmpty {
            source = "entries e"
            conditions += ["e.name_key >= ?", "e.name_key < ?"]
            values = [.text(first), .text(first + "\u{10FFFF}")]
        } else {
            source = "name_fts CROSS JOIN entries e ON e.rowid = name_fts.rowid"
            conditions.append("name_fts MATCH ?")
            values = [.text(match)]
        }
        conditions += words.map { _ in "instr(e.name_key, ?) > 0" }
        try db.query("""
            WITH hits AS MATERIALIZED (
                SELECT e.rowid AS entry_id, \(column) AS sort_key
                FROM \(source) WHERE \(conditions.joined(separator: " AND "))
                ORDER BY sort_key \(direction), entry_id \(direction) LIMIT ? OFFSET ?
            )
            SELECT \(columns) FROM hits JOIN entries e ON e.rowid = hits.entry_id
            ORDER BY hits.sort_key \(direction), hits.entry_id \(direction)
            """, values + wordValues + bounds) { rows.append(indexEntry($0)) }
        var similarNames = Set<EntryKey>()
        if filters.similar, offset == 0, rows.count < min(count, 6),
           let similarity = SimilarNames(tokens.joined(separator: " ")) {
            let exact = Set(rows.map(\.id))
            let limit = min(count - rows.count, 12)
            let ids = try similarity.candidates(in: db, where: basePredicate, limit: limit + rows.count)
            if !ids.isEmpty {
                let ranked = ids.indices.map { "(?, \($0))" }.joined(separator: ", ")
                try db.query("""
                    WITH ranked(id, priority) AS (VALUES \(ranked))
                    SELECT \(columns) FROM ranked CROSS JOIN entries e ON e.rowid = ranked.id ORDER BY ranked.priority
                    """, ids.map(SQLValue.int)) { row in
                        let entry = indexEntry(row)
                        guard !exact.contains(entry.id), similarNames.count < limit else { return }
                        similarNames.insert(entry.id)
                        rows.append(entry)
                    }
            }
        }
        return EntryPage(rows: try withFootprints(rows.prefix(count), in: db, measured: measured),
                         hasMore: rows.count > count, similarNames: similarNames)
    }

    private func sortColumn(_ sort: EntrySort, entries: String, mixed: Bool, measured: Bool,
                            rankMeasuredFoldersOnly: Bool = false) -> String {
        if sort == .allocated, mixed, measured || rankMeasuredFoldersOnly {
            let fallback = rankMeasuredFoldersOnly ? "0" : "\(entries).allocated"
            let folderSize = measured ? """
                COALESCE(
                    (SELECT exclusive + shared FROM folder_footprints
                     WHERE entry_id = \(entries).rowid AND measured > 0), \(fallback))
                """ : fallback
            return "CASE WHEN \(entries).kind = 1 THEN \(folderSize) ELSE \(entries).allocated END"
        }
        return "\(entries).\(sort == .name ? "name_key" : sort.rawValue)"
    }

    public func entry(_ key: EntryKey) throws -> StorageEntry? {
        guard let db = try database() else { return nil }
        return try db.transaction("BEGIN") {
            if key.tree == .system, try !visibleRows(in: db).isEmpty { return nil }
            var entry: StorageEntry?
            try db.query("SELECT \(entryColumns) FROM entries WHERE tree = ? AND path = ?", key.values) {
                entry = indexEntry($0)
            }
            guard let entry else { return nil }
            return try withFootprints([entry], in: db, measured: FootprintIndex.isAvailable(in: db)).first
        }
    }

    public func overview() throws -> Overview? {
        guard let db = try database() else { return nil }
        return try db.transaction("BEGIN") { try overview(in: db, includeDetails: true) }
    }

    private func overview(in db: SQLiteConnection, includeDetails: Bool) throws -> Overview? {
        guard let timestamp = try meta("updated", db: db).flatMap(Double.init) else { return nil }
        let lastAudit = try meta("checked", db: db).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let visibility = try visibleRows(in: db)
        var count: Int64 = 0
        var size: Int64 = 0
        try db.query("SELECT COALESCE(sum(files), 0), COALESCE(sum(allocated), 0) FROM entries WHERE parent IS NULL\(visibility)") {
            count = sqlInt($0, 0)
            size = sqlInt($0, 1)
        }
        let gaps = try db.integer("""
            SELECT (SELECT count(*) FROM gaps) + (
                SELECT count(*) FROM limited_scopes s
                WHERE NOT EXISTS (SELECT 1 FROM gaps g WHERE g.tree = s.tree AND g.path = s.path)
            )
            """)
        let order = includeDetails ? "date ASC" : "date DESC LIMIT 1"
        var samples: [StorageSample] = []
        try db.query("SELECT date, capacity, available, indexed FROM samples ORDER BY \(order)") { row in
            samples.append(StorageSample(date: Date(timeIntervalSince1970: sqlReal(row, 0)),
                                         capacity: sqlInt(row, 1), available: sqlInt(row, 2), indexed: sqlInt(row, 3)))
        }
        var files: [StorageEntry] = []
        var folders: [StorageEntry] = []
        if includeDetails {
            try db.query("""
                SELECT \(entryColumns) FROM entries WHERE kind <> 1\(visibility)
                ORDER BY allocated DESC, rowid DESC LIMIT 8
                """) { files.append(indexEntry($0)) }
            let measured = try FootprintIndex.isAvailable(in: db)
            files = try withFootprints(files, in: db, measured: measured)
            folders = try withFootprints(FolderRanking.load(from: db, preferFootprints: measured),
                                        in: db, measured: measured)
        }
        return Overview(indexedFiles: count, indexedBytes: size, gaps: gaps,
                        lastUpdated: Date(timeIntervalSince1970: timestamp), lastAudit: lastAudit,
                        sample: samples.last, history: includeDetails ? samples : [],
                        largeFiles: files, largeFolders: folders)
    }

    private func withFootprints(_ entries: some Collection<StorageEntry>, in db: SQLiteConnection,
                                measured: Bool) throws -> [StorageEntry] {
        guard measured else { return Array(entries) }
        return try entries.map { entry in
            var result = entry
            result.footprint = try FootprintIndex.read(entry, from: db)
            return result
        }
    }

    private func visibleRows(in db: SQLiteConnection) throws -> String {
        // A legacy database may still have the same user files under the system volume.
        try meta("topology", db: db) == StartupVolumeLayout.version ? "" : " AND tree = 0"
    }

    private func database() throws -> SQLiteConnection? {
        let path = SpaceTrailPaths.database(in: support)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let lock = try IndexFileLock(support: support, mode: LOCK_SH)
        return try SQLiteConnection(path, readOnly: true, indexLock: lock)
    }

    private func meta(_ name: String, db: SQLiteConnection) throws -> String? {
        var result: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(name)]) { result = sqlText($0, 0) }
        return result
    }
}

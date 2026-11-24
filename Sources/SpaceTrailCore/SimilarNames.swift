import Foundation
import SQLite3

struct SimilarNames {
    private let letters: [Character]
    private let terms: [Substring]
    private let suffix: String
    private let maximumEdits: Int

    init?(_ query: String) {
        let path = query as NSString
        suffix = path.pathExtension
        let stem = suffix.isEmpty ? query : path.deletingPathExtension
        terms = Self.parts(stem)
        letters = terms.flatMap { $0 }
        guard (4...48).contains(letters.count), letters.contains(where: \.isLetter) else { return nil }
        maximumEdits = letters.count >= 6 ? 2 : 1
    }

    func candidates(in db: SQLiteConnection, where predicate: String, limit: Int) throws -> [Int64] {
        guard limit > 0 else { return [] }
        let maximumLength = Int64(letters.count + maximumEdits + 18)
        let deadline = ContinuousClock.now + .milliseconds(400)
        var visited = Set<Int64>()
        var matches: [(id: Int64, edits: Int, name: String)] = []

        func collect(_ source: String, matching: String, values: [SQLValue]) throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return }
            do {
                try db.withDeadline(min(deadline, .now + .milliseconds(75))) {
                    try db.query("""
                        SELECT e.rowid, e.name_key, e.kind FROM \(source)
                        WHERE \(matching) AND \(predicate) AND length(e.name_key) <= ? LIMIT 128
                        """, values + [.int(maximumLength)]) { row in
                        let id = sqlInt(row, 0)
                        guard visited.insert(id).inserted, let name = sqlText(row, 1),
                              let edits = score(name, isFolder: sqlInt(row, 2) == EntryKind.directory.rawValue)
                        else { return }
                        matches.append((id, edits, name))
                    }
                }
            } catch let error as SQLiteFailure where error.code == SQLITE_INTERRUPT {
                try Task.checkCancellation()
            }
        }

        let grams = Self.windows(terms, width: 3)
        let pairs = Self.windows(terms, width: 4).map {
            ftsTerm(String($0.prefix(3))) + " AND " + ftsTerm(String($0.suffix(3)))
        }
        let source = "name_fts CROSS JOIN entries e ON e.rowid = name_fts.rowid"
        // Try more selective 4-character anchors before isolated trigrams.
        for match in pairs.prefix(10) {
            try collect(source, matching: "name_fts MATCH ?", values: [.text(match)])
        }
        let prefix = String(letters.prefix(2))
        let reversed = String(prefix.reversed())
        for start in Set([prefix, reversed]).sorted() {
            try collect("entries e INDEXED BY entry_name", matching: "e.name_key >= ? AND e.name_key < ?",
                        values: [.text(start), .text(start + "\u{10FFFF}")])
        }
        if matches.count < limit {
            for gram in grams.prefix(8) {
                try collect(source, matching: "name_fts MATCH ?", values: [.text(ftsTerm(gram))])
            }
        }
        return matches.sorted { ($0.edits, $0.name, $0.id) < ($1.edits, $1.name, $1.id) }.prefix(limit).map(\.id)
    }

    private func score(_ name: String, isFolder: Bool) -> Int? {
        let path = name as NSString
        let extensionInName = isFolder ? "" : path.pathExtension
        guard suffix.isEmpty || suffix == extensionInName else { return nil }
        let stem = extensionInName.isEmpty ? name : path.deletingPathExtension
        let words = Self.parts(stem)
        var best = maximumEdits + 1
        for start in words.indices {
            var candidate: [Character] = []
            for word in words[start...] {
                candidate.append(contentsOf: word)
                if candidate.count > letters.count + maximumEdits { break }
                if candidate.count >= letters.count - maximumEdits {
                    best = min(best, distance(to: candidate))
                    if best == 0 { return 0 }
                }
            }
        }
        return best <= maximumEdits ? best : nil
    }

    private func distance(to candidate: [Character]) -> Int {
        var twoBack = [Int](repeating: 0, count: candidate.count + 1)
        var previous = Array(0...candidate.count)
        var current = twoBack
        for i in letters.indices {
            current[0] = i + 1
            for j in candidate.indices {
                let cost = letters[i] == candidate[j] ? 0 : 1
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
                if i > 0, j > 0, letters[i] == candidate[j - 1], letters[i - 1] == candidate[j] {
                    current[j + 1] = min(current[j + 1], twoBack[j - 1] + 1)
                }
            }
            swap(&twoBack, &previous)
            swap(&previous, &current)
        }
        return previous[candidate.count]
    }

    private static func parts(_ text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    private static func windows(_ words: [Substring], width: Int) -> [String] {
        var seen = Set<String>()
        return words.flatMap { word -> [String] in
            let scalars = Array(word.unicodeScalars)
            guard scalars.count >= width else { return [] }
            return (0...(scalars.count - width)).compactMap { start in
                let window = String(String.UnicodeScalarView(scalars[start..<(start + width)]))
                return seen.insert(window).inserted ? window : nil
            }
        }
    }
}

func ftsTerm(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

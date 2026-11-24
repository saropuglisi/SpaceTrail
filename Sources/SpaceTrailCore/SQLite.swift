import Foundation
import SQLite3

enum SQLValue {
    case text(String), int(Int64), real(Double), null
}

struct SQLiteFailure: LocalizedError {
    let code: Int32
    let operation: String
    let message: String

    var errorDescription: String? {
        switch code {
        case SQLITE_FULL:
            return "The index is out of disk space. Free up space and try again."
        case 4618, 4874:
            return "SQLite could not open the index journal. Check the available disk space and try again."
        default:
            return "SQLite (\(code)) · \(message)"
        }
    }
}

final class SQLiteConnection {
    private let handle: OpaquePointer
    private let indexLock: IndexFileLock?
    private var statements: [String: OpaquePointer] = [:]

    init(_ url: URL, readOnly: Bool, indexLock: IndexFileLock? = nil) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the index."
            if let handle { sqlite3_close(handle) }
            throw SQLiteFailure(code: code, operation: "open", message: message)
        }
        self.handle = handle
        self.indexLock = indexLock
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func releaseMemory() { sqlite3_db_release_memory(handle) }

    func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, values) { value = sqlInt($0, 0) }
        return value
    }

    func text(_ sql: String, _ values: [SQLValue] = []) throws -> String? {
        var value: String?
        try query(sql, values) { value = sqlText($0, 0) }
        return value
    }

    func checkCancellation() {
        sqlite3_progress_handler(handle, 2_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
    }

    func withDeadline<T>(_ deadline: ContinuousClock.Instant, _ work: () throws -> T) rethrows -> T {
        try withUnsafePointer(to: deadline) { pointer in
            sqlite3_progress_handler(handle, 2_000, { context in
                guard let context else { return 1 }
                let deadline = context.assumingMemoryBound(to: ContinuousClock.Instant.self).pointee
                return Task<Never, Never>.isCancelled || ContinuousClock.now >= deadline ? 1 : 0
            }, UnsafeMutableRawPointer(mutating: pointer))
            defer { checkCancellation() }
            return try work()
        }
    }

    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        try check(code, operation: sql)
    }

    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        try query(sql, values) { _ in }
    }

    func query(_ sql: String, _ values: [SQLValue] = [], row: (OpaquePointer) throws -> Void) throws {
        try queryWhile(sql, values) {
            try row($0)
            return true
        }
    }

    func queryWhile(_ sql: String, _ values: [SQLValue] = [], row: (OpaquePointer) throws -> Bool) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value):
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .int(let value): result = sqlite3_bind_int64(statement, index, value)
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            try check(result, operation: sql)
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard try row(statement) else { return }
            result = sqlite3_step(statement)
        }
        if result != SQLITE_DONE { try check(result, operation: sql) }
    }

    func transaction<T>(_ begin: String, _ work: () throws -> T) throws -> T {
        try execute(begin)
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        try check(status, operation: sql)
        guard let statement else {
            throw SQLiteFailure(code: SQLITE_MISUSE, operation: sql, message: "Empty statement.")
        }
        statements[sql] = statement
        return statement
    }

    private func check(_ code: Int32, operation: String) throws {
        guard code == SQLITE_OK else {
            throw SQLiteFailure(code: code, operation: operation, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}

func sqlText(_ row: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(row, column).map { String(cString: $0) }
}

func sqlInt(_ row: OpaquePointer, _ column: Int32) -> Int64 {
    sqlite3_column_int64(row, column)
}

func sqlReal(_ row: OpaquePointer, _ column: Int32) -> Double {
    sqlite3_column_double(row, column)
}

func foldedName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
}

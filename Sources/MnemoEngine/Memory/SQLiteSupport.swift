// A thin, deliberately small wrapper over the system `SQLite3` C API — enough
// for `SQLiteMemoryStore` / `SQLiteSummaryStore` to be readable without pulling
// in an external SQLite package (the dependency gate stays clean: `SQLite3` is
// a system module, not an SPM dependency). Not `Sendable` — only ever touched
// from inside an actor.

import Foundation
import SQLite3

// SQLite wants to know whether a bound string/blob can be freed immediately
// (STATIC) or must be copied (TRANSIENT). We always pass copies of Swift values
// whose lifetime ends with the call, so TRANSIENT is the safe default.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Anything that went wrong talking to SQLite, with the engine's message attached.
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// One open database handle plus the small set of operations the stores need.
final class SQLiteDB {
    private var handle: OpaquePointer?

    /// Open (creating if needed) the database at `url`. Applies the standard
    /// pragmas: WAL journaling, NORMAL sync, foreign keys on, a busy timeout so
    /// concurrent readers don't immediately error.
    init(path url: URL) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 3_000)
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
    }

    deinit { if let handle { sqlite3_close(handle) } }

    /// Run one or more statements that return no rows (DDL, pragmas, simple DML).
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    /// `BEGIN; <body>; COMMIT;` — rolls back if `body` throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Prepare a statement; the caller binds parameters and steps it.
    func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(stmt: stmt)
    }

    /// Run a parameterless `INSERT/UPDATE/DELETE`-style statement once.
    func run(_ sql: String, _ binds: [SQLiteValue] = []) throws {
        let s = try prepare(sql)
        defer { s.finalize() }
        for (i, v) in binds.enumerated() { try s.bind(v, at: Int32(i + 1)) }
        try s.run()
    }

    /// `VACUUM` — reclaims space left by tombstoned rows.
    func vacuum() throws { try exec("VACUUM;") }
}

/// A value that can be bound to a `?` placeholder.
enum SQLiteValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null
}

/// One prepared statement. Bind, then either `step()` row-by-row (SELECT) or
/// `run()` once (DML). Must be `finalize()`d.
final class SQLiteStatement {
    private let stmt: OpaquePointer
    init(stmt: OpaquePointer) { self.stmt = stmt }

    func finalize() { sqlite3_finalize(stmt) }

    func bind(_ value: SQLiteValue, at index: Int32) throws {
        let rc: Int32
        switch value {
        case .text(let s): rc = sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
        case .int(let i): rc = sqlite3_bind_int64(stmt, index, i)
        case .double(let d): rc = sqlite3_bind_double(stmt, index, d)
        case .blob(let d):
            rc = d.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
            }
        case .null: rc = sqlite3_bind_null(stmt, index)
        }
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: "bind failed at \(index)") }
    }

    /// Step once. Returns true if a row is available, false at the end.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: "step failed")
        }
    }

    /// Step a DML statement to completion (expects no rows).
    func run() throws {
        let more = try step()
        precondition(!more, "run() used on a statement that returned rows")
    }

    func columnText(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func columnTextOptional(_ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : columnText(i)
    }
    func columnInt(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func columnDouble(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func columnBlob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: p, count: n)
    }
}

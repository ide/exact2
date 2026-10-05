// Observe's on-disk queue in SQLite: sessions, metrics, logs, and a per-signal cursor
// marking the last row sent. Rows are kept 7 days. The database lives with the host's
// state, outside the app's `app:/` storage.
import Foundation
import SQLite3

final class ObserveStore {
    private var db: OpaquePointer?
    static let retention: TimeInterval = 7 * 24 * 3600

    init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open(directory.appendingPathComponent("observe.db").path, &db) == SQLITE_OK else { return nil }
        exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, start REAL NOT NULL, metadata TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS metrics (id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, time REAL NOT NULL,
                category TEXT NOT NULL, name TEXT NOT NULL, value REAL NOT NULL, route TEXT, updateId TEXT, params TEXT);
            CREATE TABLE IF NOT EXISTS logs (id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, time REAL NOT NULL,
                severity TEXT NOT NULL, name TEXT NOT NULL, body TEXT, attributes TEXT, dropped INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS cursors (signal TEXT PRIMARY KEY, id INTEGER NOT NULL);
            """)
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        run("DELETE FROM metrics WHERE time < ?", [cutoff])
        run("DELETE FROM logs WHERE time < ?", [cutoff])
        run("DELETE FROM sessions WHERE start < ? AND id NOT IN (SELECT session FROM metrics UNION SELECT session FROM logs)", [cutoff])
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    @discardableResult
    func run(_ sql: String, _ args: [Any?]) -> Bool {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(s) }
        bind(s, args)
        return sqlite3_step(s) == SQLITE_DONE
    }

    func rows(_ sql: String, _ args: [Any?]) -> [[Any?]] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        bind(s, args)
        var out: [[Any?]] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(s)).map { i -> Any? in
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: return sqlite3_column_int64(s, i)
                case SQLITE_FLOAT: return sqlite3_column_double(s, i)
                case SQLITE_TEXT: return String(cString: sqlite3_column_text(s, i))
                default: return nil
                }
            })
        }
        return out
    }

    private func bind(_ s: OpaquePointer?, _ args: [Any?]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(s, n, v, -1, transient)
            case let v as Double: sqlite3_bind_double(s, n, v)
            case let v as Int: sqlite3_bind_int64(s, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, n, v)
            default: sqlite3_bind_null(s, n)
            }
        }
    }

    func saveSession(_ id: String, start: Double, metadata: [String: Any]) {
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data("{}".utf8), as: UTF8.self)
        run("INSERT OR IGNORE INTO sessions (id, start, metadata) VALUES (?, ?, ?)", [id, start, json])
    }

    func addMetric(session: String, time: Double, category: String, name: String, value: Double, route: String? = nil, params: [String: Any]) {
        let json = params.isEmpty ? nil : String(decoding: (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        run("INSERT INTO metrics (session, time, category, name, value, route, params) VALUES (?, ?, ?, ?, ?, ?, ?)", [session, time, category, name, value, route, json])
    }

    func addLog(session: String, time: Double, severity: String, name: String, body: String?, attributes: [String: Any], dropped: Int) {
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        run("INSERT INTO logs (session, time, severity, name, body, attributes, dropped) VALUES (?, ?, ?, ?, ?, ?, ?)", [session, time, severity, name, body, json, dropped])
    }

    func cursor(_ signal: String) -> Int64 {
        rows("SELECT id FROM cursors WHERE signal = ?", [signal]).first?.first as? Int64 ?? -1
    }

    func setCursor(_ signal: String, _ id: Int64) {
        run("INSERT INTO cursors (signal, id) VALUES (?, ?) ON CONFLICT(signal) DO UPDATE SET id = excluded.id", [signal, id])
    }

    func maxId(_ table: String) -> Int64 {
        rows("SELECT MAX(id) FROM \(table)", []).first?.first as? Int64 ?? -1
    }

    func session(_ id: String) -> (start: Double, metadata: [String: Any])? {
        guard let row = rows("SELECT start, metadata FROM sessions WHERE id = ?", [id]).first,
              let start = row[0] as? Double, let text = row[1] as? String,
              let meta = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return (start, meta)
    }
}

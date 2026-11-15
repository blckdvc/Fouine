import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBError: Error, CustomStringConvertible {
    let description: String
}

/// Connexion SQLite minimale. Chaque connexion appartient à une seule file d'exécution.
final class Database {
    let handle: OpaquePointer

    static let schema = """
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS dirs(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE);
    CREATE TABLE IF NOT EXISTS files(
        id INTEGER PRIMARY KEY,
        dir_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        size INTEGER NOT NULL,
        mtime INTEGER NOT NULL,
        is_dir INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS files_dir ON files(dir_id);
    CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
        name, content='files', content_rowid='id',
        tokenize='trigram remove_diacritics 1', detail=none, columnsize=0);
    """
    // Choix de taille, mesurés sur 7,3 M d'entrées : l'index FTS sans positions
    // (detail=none) pèse 178 Mo au lieu de 484, et l'index sur dir_id seul évite
    // de stocker tous les noms une deuxième fois.

    /// À incrémenter quand le schéma change : l'ancien index est alors jeté et reconstruit.
    static let schemaVersion: Int32 = 2

    /// Supprime une base d'un schéma antérieur. À appeler avant toute ouverture.
    static func discardIfOutdated(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var version: Int32 = -1
        var h: OpaquePointer?
        if sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var s: OpaquePointer?
            if sqlite3_prepare_v2(h, "PRAGMA user_version", -1, &s, nil) == SQLITE_OK,
               sqlite3_step(s) == SQLITE_ROW {
                version = sqlite3_column_int(s, 0)
            }
            sqlite3_finalize(s)
        }
        sqlite3_close_v2(h)
        guard version != schemaVersion else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            sqlite3_close_v2(h)
            throw DBError(description: msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 15000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-65536;")
        try exec(Database.schema)
        try exec("PRAGMA user_version = \(Database.schemaVersion)")
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "erreur SQLite"
            sqlite3_free(err)
            throw DBError(description: msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(db: handle, sql: sql)
    }

    /// Interrompt la requête en cours sur cette connexion (sans effet s'il n'y en a pas).
    func interrupt() { sqlite3_interrupt(handle) }

    var changes: Int32 { sqlite3_changes(handle) }
}

final class Statement {
    private let stmt: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw DBError(description: String(cString: sqlite3_errmsg(db)))
        }
        stmt = s
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    func bind(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    /// Avance d'une ligne ; `true` tant qu'une ligne est disponible.
    @discardableResult
    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func reset() { sqlite3_reset(stmt) }

    func string(_ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
}

import Foundation

/// Normalise en NFC pour que l'index, les événements et les requêtes parlent la même langue.
func norm(_ s: String) -> String {
    s.utf8.allSatisfy { $0 < 0x80 } ? s : s.precomposedStringWithCanonicalMapping
}

/// Écritures dans l'index. Utilisé uniquement depuis la file d'indexation.
///
/// Modèle : `dirs.path` porte toujours une barre finale (« / », « /Users/ »),
/// le chemin complet d'une entrée est donc `dirs.path || files.name`.
final class IndexStore {
    let db: Database
    private let findDirStmt: Statement
    private let insertDirStmt: Statement
    private let updateFileStmt: Statement
    private let insertFileStmt: Statement
    private let insertDirIDStmt: Statement
    private let deleteFileStmt: Statement
    private let deleteTreeFilesStmt: Statement
    private let deleteTreeDirsStmt: Statement
    private let getMetaStmt: Statement
    private let setMetaStmt: Statement

    init(path: String) throws {
        db = try Database(path: path)
        findDirStmt = try db.prepare("SELECT id FROM dirs WHERE path = ?")
        insertDirStmt = try db.prepare(
            "INSERT INTO dirs(path) VALUES(?) ON CONFLICT(path) DO UPDATE SET path = path RETURNING id")
        updateFileStmt = try db.prepare(
            "UPDATE files SET size = ?, mtime = ?, is_dir = ? WHERE dir_id = ? AND name = ?")
        insertFileStmt = try db.prepare(
            "INSERT INTO files(dir_id, name, size, mtime, is_dir) VALUES(?,?,?,?,?)")
        insertDirIDStmt = try db.prepare("INSERT OR REPLACE INTO dirs(id, path) VALUES(?, ?)")
        deleteFileStmt = try db.prepare("DELETE FROM files WHERE dir_id = ? AND name = ?")
        deleteTreeFilesStmt = try db.prepare(
            "DELETE FROM files WHERE dir_id IN (SELECT id FROM dirs WHERE path >= ? AND path < ?)")
        deleteTreeDirsStmt = try db.prepare("DELETE FROM dirs WHERE path >= ? AND path < ?")
        getMetaStmt = try db.prepare("SELECT value FROM meta WHERE key = ?")
        setMetaStmt = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)")
    }

    func begin() { try? db.exec("BEGIN") }
    func commit() { try? db.exec("COMMIT") }

    // MARK: Triggers FTS (retirés pendant l'indexation complète, bien plus rapide ainsi)

    func enableTriggers() throws {
        try db.exec("""
            CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                INSERT INTO files_fts(rowid, name) VALUES(new.id, new.name);
            END;
            CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                INSERT INTO files_fts(files_fts, rowid, name) VALUES('delete', old.id, old.name);
            END;
            """)
    }

    func clearAll() throws {
        try db.exec("""
            DROP TRIGGER IF EXISTS files_ai;
            DROP TRIGGER IF EXISTS files_ad;
            DROP INDEX IF EXISTS files_dir;
            DELETE FROM files;
            DELETE FROM dirs;
            INSERT INTO files_fts(files_fts) VALUES('delete-all');
            DELETE FROM meta WHERE key = 'indexed';
            """)
    }

    /// Après l'insertion en masse : index des dossiers puis index plein texte, construits d'un bloc.
    func finishBulk() throws {
        try db.exec("CREATE INDEX IF NOT EXISTS files_dir ON files(dir_id);")
        try db.exec("INSERT INTO files_fts(files_fts) VALUES('rebuild');")
    }

    /// Pendant l'indexation complète, la durabilité ne sert à rien : en cas de coupure on recommence.
    func setBulkMode(_ on: Bool) {
        try? db.exec("PRAGMA synchronous = \(on ? "OFF" : "NORMAL")")
    }

    /// Inscription directe d'un dossier lu par `FastScanner` (base vide, aucun doublon possible).
    func insertBulk(_ batch: DirBatch) {
        for sub in batch.subdirs {
            insertDirIDStmt.bind(1, sub.id)
            insertDirIDStmt.bind(2, sub.key)
            insertDirIDStmt.step()
            insertDirIDStmt.reset()
        }
        for e in batch.entries {
            insertFile(dir: batch.dirID, name: e.name, size: e.size, mtime: e.mtime, isDir: e.isDir)
        }
    }

    private func insertFile(dir: Int64, name: String, size: Int64, mtime: Int64, isDir: Bool) {
        insertFileStmt.bind(1, dir)
        insertFileStmt.bind(2, name)
        insertFileStmt.bind(3, size)
        insertFileStmt.bind(4, mtime)
        insertFileStmt.bind(5, isDir ? 1 : 0)
        insertFileStmt.step()
        insertFileStmt.reset()
    }

    // MARK: Dossiers

    static func dirKey(_ path: String) -> String { path == "/" ? "/" : path + "/" }

    func findDir(key: String) -> Int64? {
        defer { findDirStmt.reset() }
        findDirStmt.bind(1, key)
        return findDirStmt.step() ? findDirStmt.int(0) : nil
    }

    @discardableResult
    func insertDir(key: String) -> Int64 {
        defer { insertDirStmt.reset() }
        insertDirStmt.bind(1, key)
        return insertDirStmt.step() ? insertDirStmt.int(0) : 0
    }

    /// Identifiant du dossier `path` (sans barre finale), créé avec ses parents si besoin.
    func ensureDir(_ path: String) -> Int64 {
        let key = IndexStore.dirKey(path)
        if let id = findDir(key: key) { return id }
        if path != "/" {
            let ns = path as NSString
            let parent = ensureDir(ns.deletingLastPathComponent)
            var st = stat()
            let ok = lstat(path, &st) == 0
            upsertFile(dir: parent, name: ns.lastPathComponent, size: 0,
                       mtime: ok ? Int64(st.st_mtimespec.tv_sec) : 0, isDir: true)
        }
        return insertDir(key: key)
    }

    // MARK: Entrées

    func upsertFile(dir: Int64, name: String, size: Int64, mtime: Int64, isDir: Bool) {
        updateFileStmt.bind(1, size)
        updateFileStmt.bind(2, mtime)
        updateFileStmt.bind(3, isDir ? 1 : 0)
        updateFileStmt.bind(4, dir)
        updateFileStmt.bind(5, name)
        updateFileStmt.step()
        updateFileStmt.reset()
        if db.changes == 0 {
            insertFile(dir: dir, name: name, size: size, mtime: mtime, isDir: isDir)
        }
    }

    func deleteFile(dir: Int64, name: String) {
        deleteFileStmt.bind(1, dir)
        deleteFileStmt.bind(2, name)
        deleteFileStmt.step()
        deleteFileStmt.reset()
    }

    /// Supprime tout le contenu indexé sous le dossier `path` (sans barre finale).
    func deleteTree(_ path: String) {
        let low = path + "/", high = path + "0"   // « 0 » suit « / » en ordre binaire
        for stmt in [deleteTreeFilesStmt, deleteTreeDirsStmt] {
            stmt.bind(1, low)
            stmt.bind(2, high)
            stmt.step()
            stmt.reset()
        }
    }

    // MARK: Méta

    func meta(_ key: String) -> String? {
        defer { getMetaStmt.reset() }
        getMetaStmt.bind(1, key)
        return getMetaStmt.step() ? getMetaStmt.string(0) : nil
    }

    func setMeta(_ key: String, _ value: String) {
        setMetaStmt.bind(1, key)
        setMetaStmt.bind(2, value)
        setMetaStmt.step()
        setMetaStmt.reset()
    }

    func countFiles() -> Int {
        guard let s = try? db.prepare("SELECT count(*) FROM files"), s.step() else { return 0 }
        return Int(s.int(0))
    }
}

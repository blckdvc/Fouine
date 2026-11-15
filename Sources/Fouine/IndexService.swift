import Foundation
import CoreServices

enum IndexState: Equatable {
    case waiting
    case indexing(Int)
    case ready(Int)
    case failed(String)
}

/// Construit l'index du disque puis le tient à jour via FSEvents.
final class IndexService {
    static let supportDir: String = {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)[0]
        return base + "/Fouine"
    }()
    static let dbPath = supportDir + "/index.sqlite"

    /// Racine indexée et emplacement de la base (paramétrables pour les essais).
    let root: String
    let dbPath: String

    init(root: String = "/", dbPath: String = IndexService.dbPath) {
        self.root = root
        self.dbPath = dbPath
    }

    /// Appelé sur le fil principal.
    var onState: ((IndexState) -> Void)?

    private let queue = DispatchQueue(label: "fouine.index", qos: .utility)
    private var store: IndexStore!
    private var watcher: Watcher?
    private var started = false
    private var lastCount = Date.distantPast

    /// Dossiers jamais indexés : doublon du volume de données, pseudo-fichiers,
    /// instantanés Time Machine, et notre propre base (sinon boucle d'événements).
    private let excluded: [String] = [
        "/System/Volumes",
        "/dev",
        "/private/var/vm",
        "/Volumes/.timemachine",
        "/Volumes/com.apple.TimeMachine.localsnapshots",
        IndexService.supportDir,
    ]

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            do {
                try FileManager.default.createDirectory(
                    atPath: (self.dbPath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                self.store = try IndexStore(path: self.dbPath)
            } catch {
                self.publish(.failed("\(error)"))
                return
            }
            if self.store.meta("indexed") == "1" {
                try? self.store.enableTriggers()
                self.publish(.ready(self.store.countFiles()))
                self.startWatcher()
            } else {
                self.fullIndex()
            }
        }
    }

    func reindex() {
        queue.async {
            guard self.store != nil else { return }
            self.fullIndex()
        }
    }

    // MARK: Indexation complète

    private func fullIndex() {
        watcher?.stop()
        watcher = nil
        publish(.indexing(0))
        // Repère pris avant le parcours : tout ce qui change pendant sera rejoué ensuite.
        let eventID = FSEventsGetCurrentEventId()
        do {
            let started = Date()
            try store.clearAll()
            store.setBulkMode(true)
            defer { store.setBulkMode(false) }

            // Lecture du disque en parallèle ; une seule file écrit dans la base.
            let writer = DispatchQueue(label: "fouine.index.writer", qos: .utility)
            let slots = DispatchSemaphore(value: 512)   // borne la mémoire si l'écriture prend du retard
            let store = self.store!
            var count = 0
            var sinceCommit = 0
            let scanner = FastScanner(excluded: excluded) { batch in
                slots.wait()
                writer.async {
                    store.insertBulk(batch)
                    count += batch.entries.count
                    sinceCommit += batch.entries.count
                    if sinceCommit >= 50000 {
                        sinceCommit = 0
                        store.commit()
                        store.begin()
                        self.publish(.indexing(count))
                    }
                    slots.signal()
                }
            }
            store.begin()
            scanner.run(root: root, rootID: store.ensureDir(root))
            writer.sync {}
            store.commit()
            let scanned = Date()
            publish(.indexing(count))

            try store.finishBulk()
            try store.enableTriggers()
            store.setMeta("lastEvent", String(eventID))
            store.setMeta("indexed", "1")
            store.setMeta("indexSeconds", String(format: "parcours %.1f s, index %.1f s",
                                                 scanned.timeIntervalSince(started),
                                                 Date().timeIntervalSince(scanned)))
            publish(.ready(count))
            startWatcher()
        } catch {
            publish(.failed("\(error)"))
        }
    }

    /// Reprise d'un sous-arbre après un événement (le parcours complet passe par `FastScanner`).
    @discardableResult
    private func scanTree(_ root: String, full: Bool) -> Int {
        guard let cRoot = strdup(root) else { return 0 }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(fts) }

        var count = 0
        while let ent = fts_read(fts) {
            let e = ent.pointee
            let info = Int32(e.fts_info)
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS
                || info == FTS_DC || info == FTS_DOT { continue }
            guard let st = e.fts_statp?.pointee, let cPath = e.fts_path else { continue }
            let path = String(cString: cPath)
            let isDir = info == FTS_D

            if isDir {
                if excluded.contains(path) {
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
                // Changement de volume : on n'entre pas dans les volumes réseau.
                if e.fts_level > 0, let parentStat = e.fts_parent?.pointee.fts_statp?.pointee,
                   parentStat.st_dev != st.st_dev, !isLocalVolume(path) {
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
            }

            let dirID: Int64
            let name: String
            if e.fts_level == 0 {
                if path == "/" {
                    ent.pointee.fts_number = Int(store.insertDir(key: "/"))
                    continue
                }
                let ns = norm(path) as NSString
                dirID = store.ensureDir(ns.deletingLastPathComponent)
                name = ns.lastPathComponent
            } else {
                dirID = Int64(e.fts_parent.pointee.fts_number)
                name = norm(String(cString: cPath + Int(e.fts_pathlen) - Int(e.fts_namelen)))
            }

            store.upsertFile(dir: dirID, name: name, size: isDir ? 0 : Int64(st.st_size),
                             mtime: Int64(st.st_mtimespec.tv_sec), isDir: isDir)
            if isDir {
                ent.pointee.fts_number = Int(store.insertDir(key: norm(path) + "/"))
            }

            count += 1
            if full, count % 20000 == 0 {
                store.commit()
                store.begin()
                publish(.indexing(count))
            }
        }
        return count
    }

    private func isLocalVolume(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        return (fs.f_flags & UInt32(MNT_LOCAL)) != 0
    }

    // MARK: Mise à jour en continu

    private func startWatcher() {
        let since = store.meta("lastEvent").flatMap { UInt64($0) }
            ?? UInt64(kFSEventStreamEventIdSinceNow)
        let w = Watcher { [weak self] events, lastID in
            self?.handle(events, lastID: lastID)
        }
        watcher = w
        w.start(path: root, since: since, queue: queue)
    }

    private func handle(_ events: [(path: String, flags: UInt32)], lastID: UInt64) {
        let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)
        let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
        let dataPrefix = "/System/Volumes/Data"

        var needsFull = false
        var seen = Set<String>()
        store.begin()
        for event in events {
            if event.flags & historyDone != 0 { continue }
            var path = event.path
            if path.hasPrefix(dataPrefix + "/") { path.removeFirst(dataPrefix.count) }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            path = norm(path)

            if path == root || path == "/" || path == dataPrefix {
                // L'historique FSEvents a été perdu : seul un parcours complet rattrape.
                if event.flags & mustScan != 0 { needsFull = true }
                continue
            }
            if isExcluded(path) { continue }
            let rescan = event.flags & (mustScan | renamed) != 0
            if !seen.insert(path).inserted, !rescan { continue }
            apply(path, rescan: rescan)
        }
        store.setMeta("lastEvent", String(lastID))
        store.commit()

        if needsFull {
            fullIndex()
        } else if Date().timeIntervalSince(lastCount) > 20 {
            lastCount = Date()
            publish(.ready(store.countFiles()))
        }
    }

    private func isExcluded(_ path: String) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Aligne l'index sur l'état réel de `path`.
    private func apply(_ path: String, rescan: Bool) {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        let wasDir = store.findDir(key: path + "/") != nil

        var st = stat()
        guard lstat(path, &st) == 0 else {
            if let dirID = store.findDir(key: IndexStore.dirKey(parent)) {
                store.deleteFile(dir: dirID, name: name)
            }
            if wasDir { store.deleteTree(path) }
            return
        }

        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if isDir, !wasDir || rescan {
            // Dossier nouveau, renommé ou signalé incomplet : on reprend son contenu.
            if wasDir { store.deleteTree(path) }
            scanTree(path, full: false)
            return
        }
        if !isDir, wasDir { store.deleteTree(path) }
        store.upsertFile(dir: store.ensureDir(parent), name: name,
                         size: isDir ? 0 : Int64(st.st_size),
                         mtime: Int64(st.st_mtimespec.tv_sec), isDir: isDir)
    }

    private func publish(_ state: IndexState) {
        DispatchQueue.main.async { self.onState?(state) }
    }
}

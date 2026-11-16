import Foundation

/// Contenu d'un dossier, prêt à être inscrit dans l'index.
struct DirBatch {
    struct Entry {
        let name: String
        let size: Int64
        let mtime: Int64
        let isDir: Bool
    }
    let dirID: Int64
    var entries: [Entry] = []
    /// Sous-dossiers à parcourir : identifiant attribué et clé (chemin avec barre finale).
    var subdirs: [(id: Int64, key: String, mtime: Int64)] = []
}

/// Parcours complet du disque, en parallèle.
///
/// Chaque dossier est lu d'un seul appel système (`getattrlistbulk` rend noms, types,
/// tailles et dates en bloc, sans `stat` par fichier) et plusieurs dossiers sont lus en
/// même temps. Les identifiants de dossiers sont attribués ici, pour que les enfants
/// puissent être inscrits sans attendre l'écriture du parent.
final class FastScanner {
    private let excluded: Set<String>
    /// Faux : le contenu des dossiers techniques (caches…) n'est pas lu.
    private let includeTechnical: Bool
    private let sink: (DirBatch) -> Void
    /// Une file par volume : un disque lent (RAID externe…) ne retient pas les fils des SSD.
    private var queues: [dev_t: OperationQueue] = [:]
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private var nextDirID: Int64 = 0
    private var localVolumes: [dev_t: Bool] = [:]

    // Constantes de <sys/attr.h> et <sys/vnode.h>
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileDataLength: UInt32 = 0x0000_0200
    private static let typeDirectory: UInt32 = 2

    /// `sink` est appelé depuis plusieurs fils à la fois.
    init(excluded: [String], includeTechnical: Bool, sink: @escaping (DirBatch) -> Void) {
        self.excluded = Set(excluded)
        self.includeTechnical = includeTechnical
        self.sink = sink
    }

    /// Parcourt `root` (déjà inscrit sous `rootID`) et ne rend la main qu'une fois tout lu.
    func run(root: String, rootID: Int64) {
        nextDirID = rootID + 1
        var st = stat()
        let dev = lstat(root, &st) == 0 ? st.st_dev : 0
        enqueue(path: root, id: rootID, dev: dev)
        pending.wait()
    }

    private func enqueue(path: String, id: Int64, dev: dev_t) {
        pending.enter()
        queue(for: dev).addOperation { [unowned self] in
            self.scan(path: path, id: id, dev: dev)
            self.pending.leave()
        }
    }

    private func queue(for dev: dev_t) -> OperationQueue {
        lock.lock()
        defer { lock.unlock() }
        if let known = queues[dev] { return known }
        let queue = OperationQueue()
        // Mesuré : au-delà de 8 fils par volume, les lectures se gênent dans le noyau
        // (28 fils : 3,2 s pour ~/Library ; 6 à 8 fils : 1,0 à 1,2 s).
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .utility
        queues[dev] = queue
        return queue
    }

    private func allocateDirID() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextDirID
        nextDirID += 1
        return id
    }

    /// Les volumes réseau ne sont pas indexés.
    private func isLocal(_ path: String, dev: dev_t) -> Bool {
        lock.lock()
        if let known = localVolumes[dev] {
            lock.unlock()
            return known
        }
        lock.unlock()
        var fs = statfs()
        let local = statfs(path, &fs) == 0 && (fs.f_flags & UInt32(MNT_LOCAL)) != 0
        lock.lock()
        localVolumes[dev] = local
        lock.unlock()
        return local
    }

    private func scan(path: String, id: Int64, dev: dev_t) {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = FastScanner.cmnReturnedAttrs | FastScanner.cmnName | FastScanner.cmnDevID
            | FastScanner.cmnObjType | FastScanner.cmnModTime
        request.fileattr = FastScanner.fileDataLength

        let capacity = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }

        var batch = DirBatch(dirID: id)
        let prefix = path == "/" ? "/" : path + "/"
        let dirName = (path as NSString).lastPathComponent

        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                entry += length

                // Les attributs suivent dans l'ordre de leurs bits, uniquement s'ils sont rendus.
                guard returned.commonattr & FastScanner.cmnName != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let rawName = String(cString: (field + Int(nameRef.attr_dataoffset))
                    .assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                var entryDev = dev
                if returned.commonattr & FastScanner.cmnDevID != 0 {
                    entryDev = field.loadUnaligned(as: dev_t.self)
                    field += MemoryLayout<dev_t>.size
                }
                var type: UInt32 = 0
                if returned.commonattr & FastScanner.cmnObjType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var mtime: Int64 = 0
                if returned.commonattr & FastScanner.cmnModTime != 0 {
                    mtime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var size: Int64 = 0
                if returned.fileattr & FastScanner.fileDataLength != 0 {
                    size = field.loadUnaligned(as: off_t.self)
                }

                let name = norm(rawName)
                if type == FastScanner.typeDirectory {
                    let childPath = prefix + rawName
                    if excluded.contains(childPath) { continue }
                    if entryDev != dev, !isLocal(childPath, dev: entryDev) { continue }
                    if !includeTechnical, Noise.isContainer(name: rawName, parent: dirName) {
                        // Le dossier figure dans l'index, son contenu non.
                        batch.entries.append(.init(name: name, size: 0, mtime: mtime, isDir: true))
                        continue
                    }
                    let childID = allocateDirID()
                    batch.entries.append(.init(name: name, size: 0, mtime: mtime, isDir: true))
                    batch.subdirs.append((childID, norm(childPath) + "/", mtime))
                    enqueue(path: childPath, id: childID, dev: entryDev)
                } else {
                    batch.entries.append(.init(name: name, size: size, mtime: mtime, isDir: false))
                }
            }
        }
        if !batch.entries.isEmpty { sink(batch) }
    }
}

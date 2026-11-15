import Foundation
import SQLite3
import UniformTypeIdentifiers

enum SearchTarget: String, CaseIterable, Identifiable {
    case name = "Noms"
    case content = "Contenus"
    var id: String { rawValue }
}

enum SearchKind: String, CaseIterable, Identifiable {
    case all = "Fichiers et dossiers"
    case files = "Fichiers seulement"
    case folders = "Dossiers seulement"
    var id: String { rawValue }
}

enum SearchOperator: String, CaseIterable, Identifiable {
    case all = "Tous les mots"
    case any = "Un des mots"
    case phrase = "Expression exacte"
    case wildcard = "Jokers (* et ?)"
    case regex = "Expression régulière"
    var id: String { rawValue }
    /// Les jokers et les expressions régulières portent sur le nom entier, pas sur des mots.
    var isPattern: Bool { self == .wildcard || self == .regex }
}

enum TypeFilter: String, CaseIterable, Identifiable {
    case any = "Tous les types"
    case images = "Images"
    case audio = "Audio"
    case video = "Vidéo"
    case documents = "Documents"
    case archives = "Archives"
    case code = "Code"
    case apps = "Applications"
    var id: String { rawValue }

    var extensions: [String] {
        switch self {
        case .any: return []
        case .images: return ["jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "bmp", "webp", "svg", "raw", "psd"]
        case .audio: return ["mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "mid", "midi"]
        case .video: return ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]
        case .documents: return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
                                 "txt", "rtf", "md", "csv", "odt", "ods", "odp"]
        case .archives: return ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg"]
        case .code: return ["swift", "py", "js", "ts", "c", "h", "cpp", "m", "java", "rb", "go", "rs", "sh",
                            "php", "html", "css", "json", "xml", "yml", "yaml", "sql"]
        case .apps: return ["app"]
        }
    }
}

enum DateFilter: String, CaseIterable, Identifiable {
    case any = "Toutes les dates"
    case today = "Aujourd'hui"
    case week = "7 derniers jours"
    case month = "30 derniers jours"
    case year = "12 derniers mois"
    var id: String { rawValue }

    var since: Int64? {
        let now = Date()
        switch self {
        case .any: return nil
        case .today: return Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        case .week: return Int64(now.timeIntervalSince1970) - 7 * 86400
        case .month: return Int64(now.timeIntervalSince1970) - 30 * 86400
        case .year: return Int64(now.timeIntervalSince1970) - 365 * 86400
        }
    }
}

enum SizeFilter: String, CaseIterable, Identifiable {
    case any = "Toutes les tailles"
    case mb1 = "Plus de 1 Mo"
    case mb100 = "Plus de 100 Mo"
    case gb1 = "Plus de 1 Go"
    var id: String { rawValue }

    var minBytes: Int64? {
        switch self {
        case .any: return nil
        case .mb1: return 1_000_000
        case .mb100: return 100_000_000
        case .gb1: return 1_000_000_000
        }
    }
}

struct SearchOptions {
    var text = ""
    var target = SearchTarget.name
    var kind = SearchKind.all
    var op = SearchOperator.all
    var caseSensitive = false
    /// Dossier de recherche sans barre finale ; `nil` = tout le disque.
    var scope: String?
    var type = TypeFilter.any
    var date = DateFilter.any
    var size = SizeFilter.any
    var includeHidden = true
    var includePackages = false

    var tokens: [String] {
        let t = norm(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if t.isEmpty { return [] }
        return op == .phrase || op.isPattern ? [t] : t.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

struct FileHit: Identifiable, Hashable {
    let id: Int64
    let dir: String
    let name: String
    let size: Int64
    let mtime: Date
    let isDir: Bool
    var path: String { dir + name }
    /// Libellé de type localisé (« Dossier », « Image JPEG »…).
    var kind: String { KindCache.describe(name: name, isDir: isDir) }
}

enum KindCache {
    private static let lock = NSLock()
    private static var byExtension: [String: String] = [:]

    static func describe(name: String, isDir: Bool) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let key = (isDir ? "d:" : "f:") + ext
        lock.lock()
        defer { lock.unlock() }
        if let known = byExtension[key] { return known }
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let label: String
        if isDir, type?.conforms(to: .package) != true {
            label = L("Dossier")
        } else if let description = type?.localizedDescription, !description.isEmpty {
            label = description.prefix(1).uppercased() + description.dropFirst()
        } else {
            label = ext.isEmpty ? L("Document") : ext.uppercased()
        }
        byExtension[key] = label
        return label
    }
}

/// Paquets dont le contenu est masqué par défaut, comme dans le Finder.
private let packageExtensions = [
    "app", "framework", "bundle", "plugin", "kext", "appex", "photoslibrary", "musiclibrary",
    "xcodeproj", "xcworkspace", "pkg", "component", "vst", "vst3", "logicx", "band",
]

/// Expression régulière de la requête en cours (lue par la fonction SQL `regexp`, file des noms uniquement).
private var currentRegex: NSRegularExpression?

private func likeEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}

/// Trigrammes d'un terme, entre guillemets pour une requête FTS5.
private func trigrams(_ token: String) -> [String] {
    let scalars = Array(token.unicodeScalars)
    guard scalars.count >= 3 else { return [] }
    return (0...(scalars.count - 3)).map { i in
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[i..<(i + 3)])
        return "\"" + String(piece).replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Conditions communes aux deux recherches : type, date, taille, invisibles, paquets, périmètre.
private func filterSQL(_ o: SearchOptions, texts: inout [String]) -> String {
    var sql = ""
    switch o.kind {
    case .all: break
    case .files: sql += " AND f.is_dir = 0"
    case .folders: sql += " AND f.is_dir = 1"
    }
    let exts = o.type.extensions
    if !exts.isEmpty {
        sql += " AND (" + exts.map { _ in "f.name LIKE ?" }.joined(separator: " OR ") + ")"
        texts.append(contentsOf: exts.map { "%." + $0 })
    }
    if let since = o.date.since { sql += " AND f.mtime >= \(since)" }
    if let minBytes = o.size.minBytes { sql += " AND f.is_dir = 0 AND f.size >= \(minBytes)" }
    if !o.includeHidden { sql += " AND f.name NOT LIKE '.%' AND d.path NOT LIKE '%/.%'" }
    if !o.includePackages {
        for ext in packageExtensions { sql += " AND d.path NOT LIKE '%.\(ext)/%'" }
    }
    if let scope = o.scope {
        sql += " AND d.path >= ? AND d.path < ?"
        texts.append(scope + "/")
        texts.append(scope + "0")
    }
    return sql
}

final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Lectures de l'index : noms (instantané, via FTS trigramme) et contenus (lecture des fichiers à la demande).
final class SearchEngine {
    static let limit = 100_000

    private let nameDB: Database
    private let contentDB: Database
    private let nameQueue = DispatchQueue(label: "fouine.search.name", qos: .userInitiated)
    private let contentQueue = DispatchQueue(label: "fouine.search.content", qos: .userInitiated)

    init(path: String) throws {
        nameDB = try Database(path: path)
        contentDB = try Database(path: path)
        sqlite3_create_function(nameDB.handle, "fmatch", 2, SQLITE_UTF8, nil, { ctx, _, argv in
            guard let argv, let rawName = sqlite3_value_text(argv[0]),
                  let rawToken = sqlite3_value_text(argv[1]) else {
                sqlite3_result_int(ctx, 0)
                return
            }
            let found = String(cString: rawName).range(
                of: String(cString: rawToken), options: [.caseInsensitive, .diacriticInsensitive]) != nil
            sqlite3_result_int(ctx, found ? 1 : 0)
        }, nil, nil)
        // SQLite n'a pas de REGEXP d'origine : on le fournit.
        sqlite3_create_function(nameDB.handle, "regexp", 2, SQLITE_UTF8, nil, { ctx, _, argv in
            guard let regex = currentRegex, let argv, let raw = sqlite3_value_text(argv[1]) else {
                sqlite3_result_int(ctx, 0)
                return
            }
            let value = String(cString: raw)
            let found = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            sqlite3_result_int(ctx, found ? 1 : 0)
        }, nil, nil)
    }

    // MARK: Noms

    func searchNames(_ options: SearchOptions, completion: @escaping ([FileHit]) -> Void) {
        nameDB.interrupt()   // abandonne la requête précédente, devenue inutile
        nameQueue.async {
            let hits = self.runNameQuery(options)
            DispatchQueue.main.async { completion(hits) }
        }
    }

    private func runNameQuery(_ o: SearchOptions) -> [FileHit] {
        let tokens = o.tokens
        guard !tokens.isEmpty else { return [] }

        var sql = "SELECT f.id, d.path, f.name, f.size, f.mtime, f.is_dir FROM "
        var texts: [String] = []
        let glue = o.op == .any ? " OR " : " AND "

        if o.op == .regex {
            guard let regex = try? NSRegularExpression(pattern: tokens[0], options: [.caseInsensitive]) else {
                return []
            }
            currentRegex = regex
            sql += "files f JOIN dirs d ON d.id = f.dir_id WHERE f.name REGEXP ?"
            texts.append(tokens[0])
        } else if o.op == .wildcard {
            sql += "files f JOIN dirs d ON d.id = f.dir_id WHERE f.name LIKE ? ESCAPE '\\'"
            texts.append(likeEscape(tokens[0])
                .replacingOccurrences(of: "*", with: "%")
                .replacingOccurrences(of: "?", with: "_"))
        } else if indexIsReady(), tokens.allSatisfy({ $0.unicodeScalars.count >= 3 }) {
            // Le FTS trigramme exige 3 caractères par terme et un index terminé ; sinon balayage LIKE.
            // L'index (sans positions) rend les noms contenant tous les trigrammes du terme ;
            // `fmatch` confirme ensuite la présence réelle du terme.
            sql += "files_fts JOIN files f ON f.id = files_fts.rowid JOIN dirs d ON d.id = f.dir_id"
                + " WHERE files_fts MATCH ? AND ("
                + tokens.map { _ in "fmatch(f.name, ?)" }.joined(separator: glue) + ")"
            texts.append(tokens.map { "(" + trigrams($0).joined(separator: " AND ") + ")" }
                .joined(separator: glue))
            texts.append(contentsOf: tokens)
        } else {
            sql += "files f JOIN dirs d ON d.id = f.dir_id WHERE ("
                + tokens.map { _ in "f.name LIKE ? ESCAPE '\\'" }.joined(separator: glue) + ")"
            texts.append(contentsOf: tokens.map { "%" + likeEscape($0) + "%" })
        }
        sql += filterSQL(o, texts: &texts)
        sql += " LIMIT \(SearchEngine.limit)"

        guard let stmt = try? nameDB.prepare(sql) else { return [] }
        for (i, t) in texts.enumerated() { stmt.bind(Int32(i + 1), t) }
        var hits: [FileHit] = []
        while stmt.step() {
            hits.append(FileHit(
                id: stmt.int(0), dir: stmt.string(1), name: stmt.string(2), size: stmt.int(3),
                mtime: Date(timeIntervalSince1970: TimeInterval(stmt.int(4))), isDir: stmt.int(5) != 0))
        }
        return hits
    }

    private func indexIsReady() -> Bool {
        guard let s = try? nameDB.prepare("SELECT value FROM meta WHERE key = 'indexed'") else { return false }
        return s.step() && s.string(0) == "1"
    }

    // MARK: Contenus

    /// Lit les fichiers du périmètre et signale ceux qui contiennent les termes.
    /// `onProgress(nouveaux résultats, fichiers examinés)` et `onDone` arrivent sur le fil principal.
    func searchContents(_ options: SearchOptions, token: CancelToken,
                        onProgress: @escaping ([FileHit], Int) -> Void,
                        onDone: @escaping () -> Void) {
        contentQueue.async {
            self.runContentSearch(options, token: token, onProgress: onProgress)
            DispatchQueue.main.async(execute: onDone)
        }
    }

    private func runContentSearch(_ o: SearchOptions, token: CancelToken,
                                  onProgress: @escaping ([FileHit], Int) -> Void) {
        let fold = !o.caseSensitive
        let needles: [[UInt8]] = o.tokens.map { t in
            fold ? t.utf8.map { $0 >= 65 && $0 <= 90 ? $0 | 0x20 : $0 } : Array(t.utf8)
        }
        guard !needles.isEmpty else { return }
        let needAll = o.op != .any

        var filters = o
        filters.kind = .files
        var texts: [String] = []
        let sql = "SELECT f.id, d.path, f.name, f.size, f.mtime FROM dirs d JOIN files f ON f.dir_id = d.id"
            + " WHERE f.size > 0" + filterSQL(filters, texts: &texts)
        guard let stmt = try? contentDB.prepare(sql) else { return }
        for (i, t) in texts.enumerated() { stmt.bind(Int32(i + 1), t) }

        let lock = NSLock()
        var scanned = 0, found = 0
        var batch: [FileHit] = []
        var more = true
        while more, !token.isCancelled, found < SearchEngine.limit {
            batch.removeAll(keepingCapacity: true)
            while batch.count < 512 {
                guard stmt.step() else { more = false; break }
                batch.append(FileHit(
                    id: stmt.int(0), dir: stmt.string(1), name: stmt.string(2), size: stmt.int(3),
                    mtime: Date(timeIntervalSince1970: TimeInterval(stmt.int(4))), isDir: false))
            }
            var matched: [FileHit] = []
            let current = batch
            DispatchQueue.concurrentPerform(iterations: current.count) { i in
                if token.isCancelled { return }
                if fileContains(path: current[i].path, needles: needles, fold: fold, needAll: needAll) {
                    lock.lock()
                    matched.append(current[i])
                    lock.unlock()
                }
            }
            scanned += current.count
            found += matched.count
            let total = scanned
            if !token.isCancelled {
                DispatchQueue.main.async { onProgress(matched, total) }
            }
        }
    }
}

// MARK: Recherche d'octets dans un fichier

private let SF_DATALESS_FLAG: UInt32 = 0x4000_0000

/// Vrai si le fichier contient les termes (tous ou au moins un). Lecture par blocs avec recouvrement.
private func fileContains(path: String, needles: [[UInt8]], fold: Bool, needAll: Bool) -> Bool {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
    // Fichier cloud non téléchargé : le lire déclencherait son rapatriement.
    if st.st_flags & SF_DATALESS_FLAG != 0 { return false }

    let overlap = (needles.map(\.count).max() ?? 1) - 1
    let chunk = min(max(Int(st.st_size), 4096), 1 << 20)
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk + overlap)
    defer { buffer.deallocate() }

    var pending = Array(needles.indices)
    var carry = 0
    while true {
        let n = read(fd, buffer + carry, chunk)
        if n <= 0 { break }
        let total = carry + n
        let hay = UnsafeBufferPointer(start: buffer, count: total)
        pending.removeAll { idx in
            contains(hay, needles[idx], fold: fold)
        }
        if needAll ? pending.isEmpty : pending.count < needles.count { return true }
        carry = min(overlap, total)
        if carry > 0 { memmove(buffer, buffer + total - carry, carry) }
    }
    return false
}

private func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], fold: Bool) -> Bool {
    let m = needle.count, n = hay.count
    guard m > 0, n >= m, let base = hay.baseAddress else { return false }
    if !fold {
        return needle.withUnsafeBufferPointer { memmem(base, n, $0.baseAddress, m) != nil }
    }
    return needle.withUnsafeBufferPointer { nd -> Bool in
        let first = nd[0]
        var i = 0
        let last = n - m
        while i <= last {
            var b = base[i]
            if b >= 65 && b <= 90 { b |= 0x20 }
            if b == first {
                var j = 1
                while j < m {
                    var c = base[i + j]
                    if c >= 65 && c <= 90 { c |= 0x20 }
                    if c != nd[j] { break }
                    j += 1
                }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }
}

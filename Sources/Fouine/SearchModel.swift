import AppKit
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    // Critères
    @Published var query = "" { didSet { optionsChanged() } }
    @Published var target = SearchTarget.name { didSet { targetChanged() } }
    @Published var kind = SearchKind.all { didSet { optionsChanged() } }
    @Published var op = SearchOperator.all { didSet { optionsChanged() } }
    @Published var caseSensitive = false
    @Published var scope: String? { didSet { optionsChanged() } }
    @Published var bootVolumeOnly = false { didSet { optionsChanged() } }
    @Published var typeFilter = TypeFilter.any { didSet { optionsChanged() } }
    @Published var dateFilter = DateFilter.any { didSet { optionsChanged() } }
    @Published var sizeFilter = SizeFilter.any { didSet { optionsChanged() } }
    @Published var includeHidden = true { didSet { optionsChanged() } }
    @Published var includePackages = false { didSet { optionsChanged() } }

    // Résultats
    /// Liste triée affichée. `resultsVersion` change avec elle, pour que le tableau
    /// sache qu'il doit se recharger sans comparer des centaines de milliers de lignes.
    @Published private(set) var results: [FileHit] = []
    @Published private(set) var resultsVersion = 0
    /// Regroupe les dossiers avant les fichiers au lieu de les mélanger.
    @Published var foldersFirst = true { didSet { present(unsorted) } }
    /// Termes surlignés dans les noms (ceux de la dernière recherche par nom).
    @Published var highlightTokens: [String] = []
    @Published var searching = false
    @Published var searchInfo = ""
    @Published var indexState = IndexState.waiting
    @Published var needsFullDiskAccess = false
    @Published private(set) var volumes: [Volume] = []

    struct Volume: Identifiable {
        let name: String
        /// `nil` pour le volume de démarrage.
        let path: String?
        var id: String { path ?? "/" }
    }

    private let service = IndexService()
    private var engine: SearchEngine?
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private var contentToken: CancelToken?
    private var accessTimer: Timer?

    // Tri : toujours hors du fil principal, pour ne jamais figer l'interface.
    private var unsorted: [FileHit] = []
    private var sortKey = SortKey.name
    private var ascending = true
    private var sortGeneration = 0
    private let sortQueue = DispatchQueue(label: "fouine.sort", qos: .userInitiated)

    init() {
        Database.discardIfOutdated(path: IndexService.dbPath)
        service.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.indexState = state }
        }
        service.onRefreshed = { [weak self] seconds, changed in
            MainActor.assumeIsolated {
                self?.searchInfo = L("Index rafraîchi en %@ s — %@ dossiers modifiés",
                                     seconds.formatted(.number.precision(.fractionLength(1))),
                                     changed.formatted())
            }
        }
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
        if SearchModel.hasFullDiskAccess {
            startIndexing()
        } else {
            needsFullDiskAccess = true
            accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if SearchModel.hasFullDiskAccess { self?.startIndexing() }
                }
            }
        }
    }

    // MARK: Accès complet au disque

    /// Ce fichier système n'est lisible qu'avec « Accès complet au disque ».
    static var hasFullDiskAccess: Bool {
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func startIndexing() {
        accessTimer?.invalidate()
        accessTimer = nil
        needsFullDiskAccess = false
        service.start()
    }

    /// Reconstruction complète (secours).
    func reindex() { service.reindex() }

    /// Rafraîchissement différentiel : ne relit que les dossiers modifiés.
    func refresh() { service.refresh() }

    // MARK: Recherche

    var options: SearchOptions {
        SearchOptions(text: query, target: target, kind: kind, op: op, caseSensitive: caseSensitive,
                      scope: scope, bootVolumeOnly: bootVolumeOnly, type: typeFilter, date: dateFilter,
                      size: sizeFilter, includeHidden: includeHidden, includePackages: includePackages)
    }

    private func loadEngine() -> SearchEngine? {
        if engine == nil, FileManager.default.fileExists(atPath: IndexService.dbPath) {
            engine = try? SearchEngine(path: IndexService.dbPath)
        }
        return engine
    }

    /// Les noms se cherchent à la frappe ; les contenus attendent la touche Retour.
    private func optionsChanged() {
        guard target == .name else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runNameSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func targetChanged() {
        cancelContentSearch()
        if target == .name {
            optionsChanged()
        } else {
            generation += 1
            highlightTokens = []
            present([])
            searchInfo = query.isEmpty ? "" : L("Appuyez sur Retour pour chercher dans les contenus")
        }
    }

    func submit() {
        debounce?.cancel()
        if target == .name { runNameSearch() } else { runContentSearch() }
    }

    private func runNameSearch() {
        generation += 1
        let gen = generation
        let o = options
        guard !o.tokens.isEmpty, let engine = loadEngine() else {
            present([])
            searchInfo = ""
            searching = false
            return
        }
        searching = true
        engine.searchNames(o) { [weak self] hits in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.highlightTokens = o.op.isPattern ? [] : o.tokens
                self.present(hits)
                self.searching = false
                let capped = hits.count == SearchEngine.limit || hits.count == SearchEngine.shortLimit
                self.searchInfo = capped
                    ? L("%@ premiers résultats — affinez la recherche", hits.count.formatted())
                    : resultLabel(hits.count)
            }
        }
    }

    private func runContentSearch() {
        cancelContentSearch()
        generation += 1
        let gen = generation
        let o = options
        highlightTokens = []
        present([])
        guard !o.tokens.isEmpty, let engine = loadEngine() else {
            searchInfo = ""
            return
        }
        let token = CancelToken()
        contentToken = token
        searching = true
        searchInfo = L("Lecture des fichiers…")
        engine.searchContents(o, token: token, onProgress: { [weak self] hits, scanned in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                if !hits.isEmpty { self.present(self.unsorted + hits) }
                self.searchInfo = L("%@ trouvés — %@ fichiers lus…",
                                    self.unsorted.count.formatted(), scanned.formatted())
            }
        }, onDone: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.searching = false
                self.contentToken = nil
                let n = self.unsorted.count
                self.searchInfo = n >= SearchEngine.limit
                    ? L("Arrêt à %@ résultats — affinez la recherche", n.formatted())
                    : resultLabel(n)
            }
        })
    }

    func cancelContentSearch() {
        guard let token = contentToken else { return }
        token.cancel()
        contentToken = nil
        generation += 1
        searching = false
        searchInfo = L("Recherche interrompue — %@", resultLabel(unsorted.count))
    }

    var canCancel: Bool { contentToken != nil }

    // MARK: Tri

    func setSort(_ key: SortKey, ascending: Bool) {
        sortKey = key
        self.ascending = ascending
        present(unsorted)
    }

    /// Trie `hits` en arrière-plan puis les affiche ; une demande plus récente annule celle-ci.
    private func present(_ hits: [FileHit]) {
        unsorted = hits
        sortGeneration += 1
        if hits.isEmpty {
            results = []
            resultsVersion += 1
            return
        }
        let gen = sortGeneration, key = sortKey, asc = ascending, grouped = foldersFirst
        sortQueue.async { [weak self] in
            let sorted = SearchModel.sorted(hits, key: key, ascending: asc, foldersFirst: grouped)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.sortGeneration else { return }
                    self.results = sorted
                    self.resultsVersion += 1
                }
            }
        }
    }

    /// Tri par clés précalculées : une comparaison de chaînes localisée par paire serait
    /// des dizaines de fois plus lente sur de grandes listes.
    nonisolated static func sorted(_ hits: [FileHit], key: SortKey, ascending: Bool,
                                   foldersFirst: Bool) -> [FileHit] {
        func order<K: Comparable>(_ keys: [K]) -> [FileHit] {
            var indices = Array(hits.indices)
            indices.sort { a, b in
                if foldersFirst, hits[a].isDir != hits[b].isDir { return hits[a].isDir }
                if keys[a] == keys[b] { return a < b }
                return ascending ? keys[a] < keys[b] : keys[a] > keys[b]
            }
            return indices.map { hits[$0] }
        }
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        switch key {
        case .name: return order(hits.map { fold($0.name) })
        case .dir: return order(hits.map { fold($0.dir) })
        case .kind: return order(hits.map(\.kind))
        case .size: return order(hits.map(\.size))
        case .mtime: return order(hits.map(\.mtime))
        }
    }

    // MARK: Périmètre

    /// Volumes locaux montés (les volumes réseau ne sont pas indexés).
    private func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true else { return nil }
            let path = norm(url.path)
            return Volume(name: values.volumeName ?? url.lastPathComponent, path: path == "/" ? nil : path)
        }
    }

    /// `path == nil` avec `bootOnly` désigne le volume de démarrage ; sans, tout le disque.
    func setScope(_ path: String?, bootOnly: Bool = false) {
        bootVolumeOnly = bootOnly
        scope = path
    }

    var scopeLabel: String {
        if bootVolumeOnly, scope == nil { return volumes.first { $0.path == nil }?.name ?? "/" }
        guard let scope else { return L("Tous les volumes") }
        return scope == NSHomeDirectory() ? L("Dossier personnel") : (scope as NSString).lastPathComponent
    }

    func chooseScope() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Chercher ici")
        if panel.runModal() == .OK, let url = panel.url {
            setScope(norm(url.path))
        }
    }

    // MARK: Actions sur les résultats

    func open(_ hits: [FileHit]) {
        for hit in hits.prefix(20) {
            NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
        }
    }

    func reveal(_ hits: [FileHit]) {
        let urls = hits.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyPaths(_ hits: [FileHit]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hits.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Met à la corbeille (récupérable) et retire de la liste ce qui a bien été déplacé.
    func trash(_ hits: [FileHit]) {
        var gone = Set<FileHit.ID>()
        for hit in hits {
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: hit.path), resultingItemURL: nil)) != nil {
                gone.insert(hit.id)
            }
        }
        guard !gone.isEmpty else { return }
        unsorted.removeAll { gone.contains($0.id) }
        results.removeAll { gone.contains($0.id) }
        resultsVersion += 1
    }
}

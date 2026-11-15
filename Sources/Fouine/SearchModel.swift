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
    @Published var typeFilter = TypeFilter.any { didSet { optionsChanged() } }
    @Published var dateFilter = DateFilter.any { didSet { optionsChanged() } }
    @Published var sizeFilter = SizeFilter.any { didSet { optionsChanged() } }
    @Published var includeHidden = true { didSet { optionsChanged() } }
    @Published var includePackages = false { didSet { optionsChanged() } }

    // Résultats
    @Published var results: [FileHit] = []
    @Published var sortOrder = [KeyPathComparator(\FileHit.name, comparator: .localizedStandard)] {
        didSet { sortResults() }
    }
    /// Regroupe les dossiers avant les fichiers au lieu de les mélanger.
    @Published var foldersFirst = true { didSet { sortResults() } }
    /// Termes surlignés dans les noms (ceux de la dernière recherche par nom).
    @Published var highlightTokens: [String] = []
    @Published var searching = false
    @Published var searchInfo = ""
    @Published var indexState = IndexState.waiting
    @Published var needsFullDiskAccess = false

    private let service = IndexService()
    private var engine: SearchEngine?
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private var contentToken: CancelToken?
    private var accessTimer: Timer?

    init() {
        Database.discardIfOutdated(path: IndexService.dbPath)
        service.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.indexState = state }
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

    func reindex() { service.reindex() }

    // MARK: Recherche

    var options: SearchOptions {
        SearchOptions(text: query, target: target, kind: kind, op: op, caseSensitive: caseSensitive,
                      scope: scope, type: typeFilter, date: dateFilter, size: sizeFilter,
                      includeHidden: includeHidden, includePackages: includePackages)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func targetChanged() {
        cancelContentSearch()
        if target == .name {
            optionsChanged()
        } else {
            generation += 1
            results = []
            highlightTokens = []
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
            results = []
            searchInfo = ""
            searching = false
            return
        }
        searching = true
        engine.searchNames(o) { [weak self] hits in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.highlightTokens = o.op.isPattern ? [] : o.tokens
                self.results = hits
                self.sortResults()
                self.searching = false
                self.searchInfo = hits.count >= SearchEngine.limit
                    ? L("%@ premiers résultats — affinez la recherche", SearchEngine.limit.formatted())
                    : resultLabel(hits.count)
            }
        }
    }

    private func runContentSearch() {
        cancelContentSearch()
        generation += 1
        let gen = generation
        let o = options
        results = []
        highlightTokens = []
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
                if !hits.isEmpty {
                    self.results.append(contentsOf: hits)
                    self.sortResults()
                }
                self.searchInfo = L("%@ trouvés — %@ fichiers lus…",
                                    self.results.count.formatted(), scanned.formatted())
            }
        }, onDone: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.searching = false
                self.contentToken = nil
                let n = self.results.count
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
        searchInfo = L("Recherche interrompue — %@", resultLabel(results.count))
    }

    var canCancel: Bool { contentToken != nil }

    private func sortResults() {
        let order = sortOrder
        let grouped = foldersFirst
        results.sort { a, b in
            if grouped, a.isDir != b.isDir { return a.isDir }
            for comparator in order {
                switch comparator.compare(a, b) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return false
        }
    }

    // MARK: Périmètre

    var scopeLabel: String {
        guard let scope else { return L("Tout le disque") }
        return scope == NSHomeDirectory() ? L("Dossier personnel") : (scope as NSString).lastPathComponent
    }

    func chooseScope() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Chercher ici")
        if panel.runModal() == .OK, let url = panel.url {
            scope = norm(url.path)
        }
    }

    // MARK: Actions sur les résultats

    func hits(_ ids: Set<FileHit.ID>) -> [FileHit] {
        results.filter { ids.contains($0.id) }
    }

    func open(_ ids: Set<FileHit.ID>) {
        for hit in hits(ids).prefix(20) {
            NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
        }
    }

    func reveal(_ ids: Set<FileHit.ID>) {
        let urls = hits(ids).map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyPaths(_ ids: Set<FileHit.ID>) {
        let text = hits(ids).map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Met à la corbeille (récupérable) et retire de la liste ce qui a bien été déplacé.
    func trash(_ ids: Set<FileHit.ID>) {
        var gone = Set<FileHit.ID>()
        for hit in hits(ids) {
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: hit.path), resultingItemURL: nil)) != nil {
                gone.insert(hit.id)
            }
        }
        results.removeAll { gone.contains($0.id) }
    }
}

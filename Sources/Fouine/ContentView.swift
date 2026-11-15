import AppKit
import QuickLook
import SwiftUI

/// Disposition reprise d'EasyFind : critères à gauche, résultats à droite,
/// actions dans la barre d'outils, chemin de la sélection en bas.
struct ContentView: View {
    @ObservedObject var model: SearchModel
    @State private var selection = Set<FileHit.ID>()
    @State private var previewURL: URL?
    @State private var confirmTrash = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.needsFullDiskAccess {
                accessBanner
                Divider()
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                VStack(spacing: 0) {
                    searchField
                    Divider()
                    table
                    Divider()
                    pathBar
                }
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .background(WindowFrameSaver(name: "FouineFenetrePrincipale"))
        .toolbar { toolbar }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            L("Placer %@ dans la corbeille ?", selectionLabel),
            isPresented: $confirmTrash
        ) {
            Button("Placer dans la corbeille", role: .destructive) {
                model.trash(selection)
                selection = []
            }
        }
        .onAppear { searchFocused = true }
    }

    private var selectionLabel: String {
        if selection.count == 1, let hit = selectedHit { return "« \(hit.name) »" }
        return L("%@ éléments", selection.count.formatted())
    }

    private var selectedHit: FileHit? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.results.first { $0.id == id }
    }

    // MARK: Barre d'outils

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Group {
                Button { model.open(selection) } label: {
                    Label("Ouvrir", systemImage: "arrow.up.forward.app")
                }
                Button { model.reveal(selection) } label: {
                    Label("Afficher dans le Finder", systemImage: "folder")
                }
                Button { showPreview() } label: {
                    Label("Coup d'œil", systemImage: "eye")
                }
                Button { model.copyPaths(selection) } label: {
                    Label("Copier le chemin", systemImage: "doc.on.doc")
                }
                Button { confirmTrash = true } label: {
                    Label("Placer dans la corbeille", systemImage: "trash")
                }
            }
            .labelStyle(.titleAndIcon)
            .disabled(selection.isEmpty)
        }
    }

    private func showPreview() {
        guard let id = selection.first, let hit = model.results.first(where: { $0.id == id }) else { return }
        previewURL = URL(fileURLWithPath: hit.path)
    }

    // MARK: Bandeau d'autorisation

    private var accessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accès complet au disque requis").font(.headline)
                Text("Ajoutez Fouine dans Réglages › Confidentialité et sécurité › Accès complet au disque, puis relancez l'app si l'indexation ne démarre pas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Ouvrir les Réglages") { model.openPrivacySettings() }
            Button("Indexer quand même") { model.startIndexing() }
                .help("Indexe ce qui est accessible ; macOS demandera l'accès dossier par dossier.")
        }
        .padding(12)
        .background(.yellow.opacity(0.18))
    }

    // MARK: Panneau des critères

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Emplacement") {
                        Menu {
                            Button("Tout le disque") { model.scope = nil }
                            Button("Dossier personnel") { model.scope = norm(NSHomeDirectory()) }
                            Divider()
                            Button("Choisir un dossier…") { model.chooseScope() }
                        } label: {
                            Text(model.scopeLabel).lineLimit(1)
                        }
                    }
                    group("Rechercher") {
                        radios($model.kind).disabled(model.target == .content)
                        radios($model.target).padding(.top, 4)
                    }
                    group("Opérateur") {
                        radios($model.op)
                    }
                    group("Filtres") {
                        menu($model.typeFilter)
                        menu($model.dateFilter)
                        menu($model.sizeFilter)
                    }
                    group("Comparaison") {
                        Toggle("Respecter la casse", isOn: $model.caseSensitive)
                            .disabled(model.target == .name)
                            .help("Les noms sont toujours cherchés sans tenir compte de la casse ni des accents.")
                    }
                    group("Inclure") {
                        Toggle("Contenu des paquets", isOn: $model.includePackages)
                        Toggle("Fichiers et dossiers invisibles", isOn: $model.includeHidden)
                    }
                    group("Affichage") {
                        Toggle("Dossiers en premier", isOn: $model.foldersFirst)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            status
        }
        .background(.background.secondary)
    }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func radios<T: CaseIterable & Identifiable & Hashable & RawRepresentable>(
        _ value: Binding<T>
    ) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        Picker("", selection: value) {
            ForEach(T.allCases) { Text(L($0.rawValue)).tag($0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private func menu<T: CaseIterable & Identifiable & Hashable & RawRepresentable>(
        _ value: Binding<T>
    ) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        Picker("", selection: value) {
            ForEach(T.allCases) { Text(L($0.rawValue)).tag($0) }
        }
        .labelsHidden()
    }

    /// État de la recherche et de l'index, en bas du panneau.
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.searchInfo.isEmpty {
                Text(model.searchInfo).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                indexStatus
                Spacer(minLength: 0)
                Button { model.reindex() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reconstruire l'index complet")
                    .disabled(!isReady)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isReady: Bool {
        if case .ready = model.indexState { return true }
        return false
    }

    @ViewBuilder
    private var indexStatus: some View {
        switch model.indexState {
        case .waiting:
            Text("Index en attente")
        case .indexing(let count):
            ProgressView().controlSize(.mini)
            Text(L("Indexation… %@ éléments", count.formatted()))
        case .ready(let count):
            Text(L("%@ éléments indexés, à jour", count.formatted()))
        case .failed(let message):
            Text(L("Erreur d'index : %@", message)).foregroundStyle(.red)
        }
    }

    // MARK: Champ de recherche

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(model.target == .name ? L("Nom de fichier ou de dossier") : L("Texte à trouver dans les fichiers"),
                      text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { model.submit() }
            if model.searching { ProgressView().controlSize(.small) }
            if model.canCancel {
                Button("Arrêter") { model.cancelContentSearch() }
            } else if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Résultats

    private var table: some View {
        Table(model.results, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Nom", value: \.name, comparator: .localizedStandard) { hit in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(highlighted(hit.name)).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 340)

            TableColumn("Modifié", value: \.mtime) { hit in
                Text(hit.mtime.formatted(date: .numeric, time: .omitted))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90, max: 120)

            TableColumn("Taille", value: \.size) { hit in
                Text(hit.isDir ? "--" : ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80, max: 110)

            TableColumn("Type", value: \.kind) { hit in
                Text(hit.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Emplacement", value: \.dir) { hit in
                Text(hit.dir)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hit.path)
            }
            .width(min: 160, ideal: 360)
        }
        .contextMenu(forSelectionType: FileHit.ID.self) { ids in
            if !ids.isEmpty {
                Button("Ouvrir") { model.open(ids) }
                Button("Afficher dans le Finder") { model.reveal(ids) }
                Divider()
                Button("Copier le chemin") { model.copyPaths(ids) }
                Divider()
                Button("Placer dans la corbeille") {
                    selection = ids
                    confirmTrash = true
                }
            }
        } primaryAction: { ids in
            model.open(ids)
        }
        .onKeyPress(.space) {
            showPreview()
            return .handled
        }
        .overlay {
            if model.results.isEmpty, !model.searching {
                Text(model.query.isEmpty ? L("Tapez pour chercher sur tout le disque") : L("Aucun résultat"))
                    .foregroundStyle(.tertiary)
                    .font(.title3)
            }
        }
    }

    /// Nom avec les termes cherchés surlignés.
    private func highlighted(_ name: String) -> AttributedString {
        var ranges: [Range<String.Index>] = []
        for token in model.highlightTokens where !token.isEmpty {
            var start = name.startIndex
            while start < name.endIndex,
                  let found = name.range(of: token, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: start..<name.endIndex), !found.isEmpty {
                ranges.append(found)
                start = found.upperBound
            }
        }
        guard !ranges.isEmpty else { return AttributedString(name) }
        ranges.sort { $0.lowerBound < $1.lowerBound }

        var out = AttributedString()
        var position = name.startIndex
        for range in ranges where range.lowerBound >= position {
            out.append(AttributedString(String(name[position..<range.lowerBound])))
            var mark = AttributedString(String(name[range]))
            mark.backgroundColor = .yellow
            mark.foregroundColor = .black
            out.append(mark)
            position = range.upperBound
        }
        out.append(AttributedString(String(name[position...])))
        return out
    }

    // MARK: Chemin de la sélection

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let hit = selectedHit {
                    let parts = hit.path.split(separator: "/").map(String.init)
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                        Image(systemName: index == parts.count - 1 && !hit.isDir ? "doc" : "folder")
                            .foregroundStyle(.secondary)
                        Text(part)
                    }
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
        }
        .frame(height: 24)
    }
}

/// Mémorise la taille et la position de la fenêtre et les restaure au lancement suivant.
struct WindowFrameSaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

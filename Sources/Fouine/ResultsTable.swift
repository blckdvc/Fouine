import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SortKey: String {
    case name, mtime, size, kind, dir
}

enum RowAction {
    case open, reveal, preview, copyPath, trash
}

/// Tableau des résultats en AppKit : seules les lignes visibles sont construites,
/// ce qui reste fluide avec 100 000 résultats (le `Table` de SwiftUI fige l'app à cette échelle).
struct ResultsTable: NSViewRepresentable {
    let rows: [FileHit]
    /// Change à chaque nouvelle liste : évite de comparer les tableaux.
    let version: Int
    let highlight: [String]
    /// Facteur de zoom : taille du texte, des icônes et hauteur des lignes.
    let zoom: CGFloat
    var onSelect: ([FileHit]) -> Void
    var onSort: (SortKey, Bool) -> Void
    var onAction: (RowAction, [FileHit]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        let coordinator = context.coordinator
        coordinator.table = table

        let columns: [(SortKey, String, CGFloat, CGFloat)] = [
            (.name, L("Nom"), 340, 160),
            (.mtime, L("Modifié"), 95, 80),
            (.size, L("Taille"), 85, 60),
            (.kind, L("Type"), 140, 70),
            (.dir, L("Emplacement"), 420, 160),
        ]
        for (key, title, width, minWidth) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            table.addTableColumn(column)
        }
        table.dataSource = coordinator
        table.delegate = coordinator
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = (22 * zoom).rounded()
        coordinator.zoom = zoom
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onKey = { [weak coordinator] action in coordinator?.perform(action, clicked: false) }
        table.menu = coordinator.makeMenu()
        // Largeur et ordre des colonnes mémorisés d'un lancement à l'autre.
        table.autosaveName = "FouineColonnesResultats"
        table.autosaveTableColumns = true
        coordinator.ignoreSortChange = true
        table.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]
        coordinator.ignoreSortChange = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.zoom != zoom {
            coordinator.zoom = zoom
            coordinator.table?.rowHeight = (22 * zoom).rounded()
            coordinator.table?.reloadData()
        }
        guard coordinator.version != version else { return }
        coordinator.version = version
        coordinator.rows = rows
        coordinator.highlight = highlight
        coordinator.table?.reloadData()
        coordinator.table?.scrollRowToVisible(0)
        DispatchQueue.main.async { coordinator.parent.onSelect([]) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResultsTable
        weak var table: NSTableView?
        var rows: [FileHit] = []
        var highlight: [String] = []
        var version = -1
        var zoom: CGFloat = 1
        var ignoreSortChange = false

        private var iconsByExtension: [String: NSImage] = [:]
        private let folderIcon = NSWorkspace.shared.icon(for: .folder)
        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            return f
        }()
        private let sizeFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f
        }()

        private let singleLine: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()

        init(_ parent: ResultsTable) { self.parent = parent }

        // MARK: Données

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count,
                  let key = SortKey(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let hit = rows[row]
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(tableColumn.identifier, key: key)
            guard let text = cell.textField else { return cell }
            let fontSize = NSFont.systemFontSize * zoom
            text.font = key == .size || key == .mtime
                ? .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                : .systemFont(ofSize: fontSize)
            for constraint in cell.imageView?.constraints ?? []
            where constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                constraint.constant = (16 * zoom).rounded()
            }
            switch key {
            case .name:
                text.attributedStringValue = highlighted(hit.name)
                cell.imageView?.image = icon(for: hit)
            case .mtime:
                text.stringValue = dateFormatter.string(from: hit.mtime)
            case .size:
                text.stringValue = hit.isDir ? "--" : sizeFormatter.string(fromByteCount: hit.size)
            case .kind:
                text.stringValue = hit.kind
            case .dir:
                text.stringValue = hit.dir
                text.toolTip = hit.path
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier, key: SortKey) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = key == .dir ? .byTruncatingMiddle : .byTruncatingTail
            text.maximumNumberOfLines = 1
            text.cell?.usesSingleLineMode = true
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.textColor = key == .name ? .labelColor : .secondaryLabelColor
            if key == .size { text.alignment = .right }
            if key == .size || key == .mtime {
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            cell.addSubview(text)
            cell.textField = text
            var leading = cell.leadingAnchor
            var gap: CGFloat = 2
            if key == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                ])
                leading = image.trailingAnchor
                gap = 6
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leading, constant: gap),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// Icône par type, mise en cache ; seules les apps ont une icône qui leur est propre.
        private func icon(for hit: FileHit) -> NSImage {
            let ext = (hit.name as NSString).pathExtension.lowercased()
            if ext == "app" { return NSWorkspace.shared.icon(forFile: hit.path) }
            if hit.isDir, ext.isEmpty { return folderIcon }
            let key = (hit.isDir ? "d:" : "f:") + ext
            if let cached = iconsByExtension[key] { return cached }
            let type = UTType(filenameExtension: ext)
            let image: NSImage
            if hit.isDir {
                // Un point dans un nom de dossier n'en fait pas un fichier : seuls les paquets ont leur icône.
                image = type?.conforms(to: .package) == true ? NSWorkspace.shared.icon(for: type!) : folderIcon
            } else {
                image = NSWorkspace.shared.icon(for: type ?? .data)
            }
            iconsByExtension[key] = image
            return image
        }

        /// Nom avec les termes cherchés surlignés.
        private func highlighted(_ name: String) -> NSAttributedString {
            let out = NSMutableAttributedString(string: name, attributes: [
                .paragraphStyle: singleLine, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize * zoom),
            ])
            let ns = name as NSString
            for token in highlight where !token.isEmpty {
                var search = NSRange(location: 0, length: ns.length)
                while search.length > 0 {
                    let found = ns.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    if found.location == NSNotFound || found.length == 0 { break }
                    out.addAttributes([.backgroundColor: NSColor.systemYellow,
                                       .foregroundColor: NSColor.black], range: found)
                    let next = found.location + found.length
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
            return out
        }

        // MARK: Sélection, tri, actions

        private var selectedHits: [FileHit] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            parent.onSelect(selectedHits)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !ignoreSortChange, let first = tableView.sortDescriptors.first,
                  let raw = first.key, let key = SortKey(rawValue: raw) else { return }
            parent.onSort(key, first.ascending)
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            perform(.open, clicked: true)
        }

        /// Cible d'une action : la ligne cliquée si elle est hors sélection, sinon la sélection.
        func perform(_ action: RowAction, clicked: Bool) {
            guard let table else { return }
            var hits = selectedHits
            let row = table.clickedRow
            if clicked, row >= 0, row < rows.count, !table.selectedRowIndexes.contains(row) {
                hits = [rows[row]]
            }
            if !hits.isEmpty { parent.onAction(action, hits) }
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            func add(_ title: String, _ selector: Selector) {
                let item = NSMenuItem(title: L(title), action: selector, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            add("Ouvrir", #selector(menuOpen))
            add("Afficher dans le Finder", #selector(menuReveal))
            add("Coup d'œil", #selector(menuPreview))
            menu.addItem(.separator())
            add("Copier le chemin", #selector(menuCopy))
            menu.addItem(.separator())
            add("Placer dans la corbeille", #selector(menuTrash))
            return menu
        }

        @objc private func menuOpen() { perform(.open, clicked: true) }
        @objc private func menuReveal() { perform(.reveal, clicked: true) }
        @objc private func menuPreview() { perform(.preview, clicked: true) }
        @objc private func menuCopy() { perform(.copyPath, clicked: true) }
        @objc private func menuTrash() { perform(.trash, clicked: true) }
    }
}

/// Espace = Coup d'œil, Retour = ouvrir.
final class KeyTableView: NSTableView {
    var onKey: ((RowAction) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": onKey?(.preview)
        case "\r": onKey?(.open)
        default: super.keyDown(with: event)
        }
    }
}

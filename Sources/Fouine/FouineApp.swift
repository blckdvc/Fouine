import AppKit
import Sparkle
import SwiftUI

/// Coordonnées affichées dans « À propos ».
enum Auteur {
    static let nom = "Ludovic Benhamou"
    static let lien = "https://github.com/blckdvc"
    static let projet = "https://github.com/blckdvc/Fouine"
}

@main
struct FouineApp: App {
    @StateObject private var model = SearchModel()
    /// Sparkle : vérifie le flux SUFeedURL en tâche de fond et propose les nouvelles versions.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Fouine", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("À propos de Fouine") { showAbout() }
                Button("Rechercher les mises à jour…") { updater.checkForUpdates(nil) }
                Divider()
                Button("Rafraîchir l'index") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Reconstruire l'index complet") { model.reindex() }
            }
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        func line(_ text: String, link: String? = nil) {
            var attrs = base
            if let link, let url = URL(string: link) { attrs[.link] = url }
            credits.append(NSAttributedString(string: text, attributes: attrs))
            credits.append(NSAttributedString(string: "\n", attributes: base))
        }
        line(L("Recherche de fichiers indexée pour macOS."))
        line("")
        line(L("Conçu et développé par %@", Auteur.nom))
        line("github.com/blckdvc", link: Auteur.lien)
        line(L("Code source et versions"), link: Auteur.projet)

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

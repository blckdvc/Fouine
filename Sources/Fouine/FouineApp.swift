import AppKit
import Sparkle
import SwiftUI

/// Coordonnées affichées dans « À propos » (mêmes éléments que dans KDownloader).
enum Auteur {
    static let pseudo = "blckdvc"
    static let don = "https://paypal.me/lbenh"
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
                AboutButton()
                Button("Rechercher les mises à jour…") { updater.checkForUpdates(nil) }
                Divider()
                Button("Rafraîchir l'index") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Reconstruire l'index complet") { model.reindex() }
            }
        }

        Window("À propos de Fouine", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

private struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("À propos de Fouine") { openWindow(id: "about") }
    }
}

/// Même composition que le « À propos » de KDownloader : logo, nom et version,
/// description, auteur, bouton de don, mentions des composants inclus.
private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text(verbatim: "Fouine \(version)")
                .font(.system(size: 17, weight: .semibold))
            Text("Recherche de fichiers pour macOS : index de tout le disque tenu à jour en continu, recherche par nom instantanée et par contenu, filtres.")
                .fixedSize(horizontal: false, vertical: true)
            Text(L("par %@", Auteur.pseudo))
            Text("Libre et open source — si le cœur vous en dit, offrez-moi quelques tokens :")
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: Auteur.don) { NSWorkspace.shared.open(url) }
            } label: {
                if let image = NSImage(named: "buy-me-tokens") {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260)
                } else {
                    Text(verbatim: "Buy me tokens")
                }
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "paypal.me/lbenh"))
            Text("Inclut Sparkle, sous sa propre licence.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 380)
    }
}

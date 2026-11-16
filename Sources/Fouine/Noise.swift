import Foundation

/// Dossiers « techniques » : caches, produits de compilation, bases internes des volumes.
/// Ils changent sans arrêt et n'intéressent presque jamais une recherche. Par défaut le
/// dossier lui-même reste dans l'index (on trouve « node_modules »), pas son contenu.
enum Noise {
    static let defaultsKey = "indexerDossiersTechniques"

    private static let names: Set<String> = [
        "Caches", "Cache", "Code Cache", "Cache_Data", "GPUCache",
        "node_modules", ".git", "DerivedData", "__pycache__", ".build",
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]

    /// Fichiers temporaires du système : écartés en entier.
    static let roots = ["/private/var/folders", "/private/tmp"]

    /// Vrai si le contenu du dossier `name`, placé dans un dossier nommé `parent`, est à écarter.
    static func isContainer(name: String, parent: String) -> Bool {
        if names.contains(name) { return true }
        // Produits de compilation Rust : target/debug et target/release.
        return parent == "target" && (name == "debug" || name == "release")
    }

    /// Vrai si le dossier `path` est lui-même un dossier technique.
    static func isContainer(path: String) -> Bool {
        let ns = path as NSString
        return isContainer(name: ns.lastPathComponent,
                           parent: (ns.deletingLastPathComponent as NSString).lastPathComponent)
    }

    /// Vrai si `path` se trouve à l'intérieur d'un dossier technique.
    static func isInside(_ path: String) -> Bool {
        var parent: Substring = ""
        let parts = path.split(separator: "/")
        for part in parts.dropLast() {
            if isContainer(name: String(part), parent: String(parent)) { return true }
            parent = part
        }
        return false
    }

    /// Empreinte du nom sur 15 bits (deux octets en base). Indexer (dossier, empreinte)
    /// retrouve une entrée sans relire son dossier, sans stocker les noms une deuxième fois.
    static func hash(_ name: String) -> Int64 {
        var h: UInt32 = 2_166_136_261
        for byte in name.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        return Int64((h ^ (h >> 15)) & 0x7FFF)
    }
}

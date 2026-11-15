import Foundation

/// Texte dans la langue du système. La clé est le texte français ;
/// les traductions vivent dans Resources/<langue>.lproj/Localizable.strings.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: .current, arguments: args)
}

func resultLabel(_ count: Int) -> String {
    count == 1 ? L("1 résultat") : L("%@ résultats", count.formatted())
}

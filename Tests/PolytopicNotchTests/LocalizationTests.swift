import Foundation
@testable import PolytopicNotch
import Testing

/// The package's catalog (`Resources/Localizable.xcstrings`) ships inside the library and is what its words use at
/// run time. Its contents are checked by `Tools/l10n/check.mjs`; these tests check that it's wired up.
struct LocalizationTests {
    static let languages = ["de", "ja", "vi", "fr", "es", "it", "pl"]
    /// SwiftPM compiles the catalog into per-language resources only with newer toolchains (Xcode does always); an older
    /// `swift build` copies it as it is, so the package shows English. The translation tests need the compiled form.
    static let catalogCompiled = Bundle.module.localizations.contains("de")

    private func text(_ key: String.LocalizationValue, in language: String) -> String {
        var resource = LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
        resource.locale = Locale(identifier: language)
        return String(localized: resource)
    }

    @Test(.enabled(if: catalogCompiled, "this toolchain copies the catalog without compiling it"))
    func everyLanguageShipsWithTheLibrary() {
        #expect(Set(Bundle.module.localizations).isSuperset(of: Self.languages))
    }

    @Test(.enabled(if: catalogCompiled, "this toolchain copies the catalog without compiling it"), arguments: languages)
    func sentencesAreTranslated(_ language: String) {
        let english = "No other app is using the notch right now."
        let translated = text("No other app is using the notch right now.", in: language)
        #expect(!translated.isEmpty)
        #expect(translated != english)
    }

    @Test func englishIsUnchanged() {
        let name = "Boring Notch", seconds = 30, one = 1, twelve = 12
        #expect(text("Sharing the notch with \(name)", in: "en") == "Sharing the notch with Boring Notch")
        #expect(text("For \(seconds) seconds", in: "en") == "For 30 seconds")
        #expect(text("\(twelve) new", in: "en") == "12 new")
        #expect(text("\(one) degrees", in: "en") == "1 degrees")
        #expect(text("NOTCH LIGHT", in: "en") == "NOTCH LIGHT")
    }

    @Test(.enabled(if: catalogCompiled, "this toolchain copies the catalog without compiling it"))
    func countsUseTheLanguagesPluralForms() {
        let one = 1, three = 3, five = 5
        // Polish: "sekundę", "sekundy", "sekund" for 1, 3 and 5.
        let forms = [one, three, five].map { text("For \($0) seconds", in: "pl").replacingOccurrences(of: "\($0)", with: "N") }
        #expect(Set(forms).count > 1)
        #expect(text("For \(three) seconds", in: "ja").contains("3"))
    }
}

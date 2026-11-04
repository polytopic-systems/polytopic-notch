# Localization

The package's own words (Settings rows, the notch light panel, the dock's list, the live list's "new" capsule,
accessibility labels) are translated into the languages in `Tools/l10n/locales.txt`. They live in
`Sources/PolytopicNotch/Resources/Localizable.xcstrings`, ship inside the library, and follow the app's language.
Text an app passes in (titles, captions, its own `NotchOwnLookText` wording or picker title) is the app's to
translate.
English is the source; the other languages are written by Claude (`Tools/l10n/translate.mjs`) and checked by
`Tools/l10n/check.mjs`. The translator reads this file, so keep it accurate.

## Writing strings

- **Always the package's bundle.** Inside a package, SwiftUI literals and `String(localized:)` look in the app's
  bundle unless told otherwise: `Text("Order", bundle: .module, comment: "…")`,
  `String(localized: "Make room", bundle: .module, comment: "…")`. For `Button`, `Toggle`, `Picker`, `.help`,
  `.accessibilityLabel` and the like, pass a `String(localized: …, bundle: .module)`.
- **Whole sentences**, with placeholders: `String(localized: "Sharing the notch with \(name)", bundle: .module)`,
  never pieces joined in code.
- **Counts** are one key with plural variations in the catalog (English `one`/`other`); the checker fails a
  language that lacks a form it needs.
- **A comment** for anything short or ambiguous ("Order", "On", "Split").
- **Not translated:** logs and diagnostics (`NotchLog`), identifiers, defaults keys, the dock's wire format, the
  DocC documentation and the example app. Numbers alone use `Text(verbatim:)`.
- A default that apps can replace (`NotchSharingPicker`'s caption, `NotchLightPicker`'s title) comes from a
  static property, since a default argument can't reach `Bundle.module`.

## Tools

```bash
Tools/l10n/extract.sh Sources/PolytopicNotch/Resources/Localizable.xcstrings PolytopicNotch   # code → catalog
node Tools/l10n/translate.mjs Sources/PolytopicNotch/Resources/Localizable.xcstrings \
    --app "PolytopicNotch, the notch pill shown at the top of the Mac screen"                 # needs the claude CLI
node Tools/l10n/check.mjs                                                                       # must say 0 errors
```

`extract.sh` builds the scheme with the compiler's string extraction and syncs the catalog (new strings in English,
removed ones marked stale, translations kept); add English plural forms by hand. `translate.mjs` only sends
strings that are missing in a language. A translation that is rightly the same as English goes in
`Tools/l10n/same-ok.txt`. `LocalizationTests` checks that the catalog ships and resolves.

## Translation rules

- Translate meaning, not words, and keep it as short as the English: these are Settings rows, tooltips and
  labels on a small panel.
- Keep every placeholder (`%@`, `%lld`, `%u`, `%1$@`) and line break exactly.
- UPPERCASE labels of the notch light panel (NOTCH LIGHT, BREATHE, STORE, APP COLOUR, INTENSITY…) stay uppercase
  and short; Japanese uses its usual script.
- Never translate names: Polytopic Systems, PolytopicNotch, Mac, macOS, and other apps and their features
  (Bartender, Top Shelf, Boring Notch, Atoll, Ice).
- Apple names use what macOS shows in that language (the Option key, System Settings).
- Plain, friendly, direct; no exclamation marks the English doesn't have.

| Language | Code | Address | Notes |
|---|---|---|---|
| German | `de` | `Sie` | Nouns capitalised |
| Japanese | `ja` | です/ます | No spaces between words; full-width 。、 |
| Vietnamese | `vi` | bạn | Full diacritics |
| French | `fr` | `vous` | Narrow no-break space (U+202F) before `: ; ? !` |
| Spanish | `es` | `usted` | Neutral Spanish |
| Italian | `it` | `tu` imperative, as Apple's Italian UI | |
| Polish | `pl` | imperative, as Apple's Polish UI | Plurals: one / few / many / other |

## Glossary

| English | de | ja | vi | fr | es | it | pl |
|---|---|---|---|---|---|---|---|
| notch | Notch | ノッチ | tai thỏ | encoche | muesca | notch | wcięcie |
| pill (the black shape at the notch) | Kapsel | ピル | viên nang | pastille | píldora | pillola | pigułka |
| dock, docks (the apps sharing the notch; not the macOS Dock) | Dock | ドック | dock | Dock | Dock | Dock | Dock |
| menu bar | Menüleiste | メニューバー | thanh menu | barre des menus | barra de menús | barra dei menu | pasek menu |
| menu bar manager | Menüleisten-Manager | メニューバー管理アプリ | trình quản lý thanh menu | gestionnaire de barre des menus | gestor de la barra de menús | gestore della barra dei menu | menedżer paska menu |
| Settings | Einstellungen | 設定 | Cài đặt | Réglages | Ajustes | Impostazioni | Ustawienia |
| quiet indicator | Ruheanzeige | 待機インジケータ | chỉ báo chờ | indicateur discret | indicador discreto | indicatore discreto | wskaźnik spoczynku |
| notch light | Notch-Licht | ノッチライト | đèn tai thỏ | lumière de l'encoche | luz de la muesca | luce del notch | światło wcięcia |
| Option (key) | Wahltaste | Optionキー | Option | Option | Opción | Opzione | Option |
| Priority (sharing style) | Priorität | 優先 | Ưu tiên | Priorité | Prioridad | Priorità | Priorytet |
| Switcher (sharing style) | Umschalter | 切り替え | Chuyển đổi | Sélecteur | Selector | Selettore | Przełącznik |
| Split (sharing style) | Geteilt | 分割 | Chia đôi | Partagé | Dividido | Diviso | Podział |
| Merged (sharing style) | Zusammengeführt | 統合 | Gộp | Fusionné | Combinado | Unito | Scalenie |

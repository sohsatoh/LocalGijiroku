import SwiftUI

/// Helpers for accessing the SwiftPM-bundled localization table. `Bundle.module`
/// is generated at build time from the `Resources/` entries declared in
/// Package.swift; using it directly avoids relying on Bundle.main (which is the
/// .app bundle and doesn't carry SPM resources).
///
/// Lookup honors the user-selected `appLanguage` setting: when set to a
/// concrete code (e.g. "ja", "en") we resolve the matching `.lproj` sub-bundle
/// so the user can override the system language without changing macOS-wide
/// preferences. Reading UserDefaults directly here avoids importing the
/// SettingsModel actor (and the @MainActor isolation that comes with it) from
/// non-MainActor call sites.
enum L10n {
    static let appLanguageKey = "appLanguage"

    /// Looks up a localized string from `Localizable.strings`, falling back to
    /// the key itself if the key is missing.
    static func string(_ key: String) -> String {
        let bundle = currentBundle()
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Formats `String(format:)` after localizing the key.
    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, locale: locale(), arguments: args)
    }

    /// Returns the bundle whose `Localizable.strings` should be consulted.
    /// "system" (or any unknown value) falls back to `Bundle.module`, which
    /// honors the OS preference order.
    private static func currentBundle() -> Bundle {
        let override = UserDefaults.standard.string(forKey: appLanguageKey) ?? "system"
        guard override != "system",
              let path = Bundle.module.path(forResource: override, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.module
        }
        return bundle
    }

    /// Locale used for number/format substitution. Falls back to `.current`
    /// when no override is set.
    static func locale() -> Locale {
        let override = UserDefaults.standard.string(forKey: appLanguageKey) ?? "system"
        if override == "system" { return .current }
        return Locale(identifier: override)
    }
}

extension Text {
    /// `Text` initializer that always looks up from the SPM bundle.
    /// Use it everywhere we want the OS-language switch to work.
    init(loc key: String) {
        self.init(L10n.string(key))
    }
}

extension Label where Title == Text, Icon == Image {
    /// Convenience for Label + SF Symbol + localized key.
    init(loc key: String, systemImage: String) {
        self.init(title: { Text(L10n.string(key)) }, icon: { Image(systemName: systemImage) })
    }
}

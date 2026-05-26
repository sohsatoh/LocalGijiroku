import SwiftUI

/// Helpers for accessing the SwiftPM-bundled localization table. `Bundle.module`
/// is generated at build time from the `Resources/` entries declared in
/// Package.swift; using it directly avoids relying on Bundle.main (which is the
/// .app bundle and doesn't carry SPM resources).
enum L10n {
    /// Looks up a localized string from `Localizable.strings`, falling back to
    /// the key itself if the key is missing.
    static func string(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    /// Formats `String(format:)` after localizing the key.
    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, locale: .current, arguments: args)
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

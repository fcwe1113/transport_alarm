import Foundation

/// Reads the same JSON catalog used by Flutter and Android notifications.
enum NativeLocalization {
    static func text(_ key: String, values: [String: Any] = [:]) -> String {
        let languageCode = UserDefaults(suiteName: AppGroup.identifier)?
            .string(forKey: "app_language_code") ?? "en"
        let catalog = loadCatalog(languageCode) ?? loadCatalog("en") ?? [:]
        var value = catalog[key] as? String ?? key
        for (name, replacement) in values {
            value = value.replacingOccurrences(
                of: "{\(name)}",
                with: String(describing: replacement)
            )
        }
        return value
    }

    private static func loadCatalog(_ languageCode: String) -> [String: Any]? {
        guard let url = Bundle.main.url(
            forResource: "strings_\(languageCode)",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return catalog
    }
}

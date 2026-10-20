import Foundation

/// Reads the same JSON catalogs as Flutter and the Android notifications,
/// bundled into each target, in the app language Dart saves to the App Group.
enum NativeLocalization {
    static let busMode = "bus"

    private static let fallbackLanguage = "en"
    private static let cacheLock = NSLock()
    private static var cachedCatalogs: [String: [String: Any]] = [:]

    /// A transport mode's name, such as "bus", or "Bus" with [titleCase].
    /// Add a transport.mode.<mode> entry to each catalog to add a mode.
    static func transportMode(_ mode: String, titleCase: Bool = false) -> String {
        let normalized = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "transport.mode.\(normalized)\(titleCase ? ".title" : "")"
        let localized = text(key)
        if localized != key { return localized }
        guard let first = normalized.first else { return "transport" }
        return titleCase ? first.uppercased() + String(normalized.dropFirst()) : normalized
    }

    /// The string for [key] with each "{name}" replaced from [values]: from
    /// the app language's catalog, then English, or the key itself.
    static func text(_ key: String, values: [String: Any] = [:]) -> String {
        let languageCode = UserDefaults(suiteName: AppGroup.identifier)?
            .string(forKey: "app_language_code") ?? fallbackLanguage
        var value = catalog(languageCode)[key] as? String
            ?? catalog(fallbackLanguage)[key] as? String
            ?? key
        for (name, replacement) in values {
            value = value.replacingOccurrences(of: "{\(name)}", with: String(describing: replacement))
        }
        return value
    }

    /// A language's catalog, read from the bundle once per process; empty if
    /// it isn't bundled.
    private static func catalog(_ languageCode: String) -> [String: Any] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedCatalogs[languageCode] { return cached }
        let loaded = Bundle.main.url(forResource: "strings_\(languageCode)", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cachedCatalogs[languageCode] = loaded
        return loaded
    }
}

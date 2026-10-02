import Foundation

/// Builds and decodes live ETA requests for one transit operator.
/// Add a provider here and register it below to support another operator.
protocol NativeTransitETAProvider {
    /// Database provider code that identifies this operator, such as `kmb`.
    var code: String { get }

    /// Builds a legacy endpoint while older saved alarms are being phased out.
    func legacyETAURL(stopID: String, routeNumber: String) -> URL?

    /// Decodes arrival timestamps from the API response for selected routes.
    func arrivalDates(from data: Data, matching routeNumbers: Set<String>) -> [Date]
}

extension NativeTransitETAProvider {
    /// KMB and Citybus currently share this response shape. An operator with a
    /// different API format can implement its own decoder in its provider.
    func arrivalDates(from data: Data, matching routeNumbers: Set<String>) -> [Date] {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = payload["data"] as? [[String: Any]] else {
            return []
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let route = row["route"] as? String,
                  routeNumbers.contains(route),
                  let rawETA = row["eta"] as? String else {
                return nil
            }
            return formatter.date(from: rawETA) ?? fallbackFormatter.date(from: rawETA)
        }
    }
}

private struct KMBETAProvider: NativeTransitETAProvider {
    let code = "kmb"

    func legacyETAURL(stopID: String, routeNumber: String) -> URL? {
        URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/eta/\(stopID)/\(routeNumber)/1")
    }
}

private struct CitybusETAProvider: NativeTransitETAProvider {
    let code = "ctb"

    func legacyETAURL(stopID: String, routeNumber: String) -> URL? {
        URL(string: "https://rt.data.gov.hk/v1/transport/citybus-nwfb/eta/CTB/\(stopID)/\(routeNumber)")
    }
}

struct NativeTransitETARequest {
    /// Fully constructed URL to fetch.
    let url: URL

    /// Transport mode selects a decoder family as more modes are added.
    let mode: String

    /// Used to choose the provider-specific response decoder after the fetch.
    let providerCode: String
}

enum NativeTransitETAProviders {
    // Registry keys must match provider_code values in the GTFS database.
    private static let registered: [String: NativeTransitETAProvider] = {
        let providers: [NativeTransitETAProvider] = [KMBETAProvider(), CitybusETAProvider()]
        return Dictionary(uniqueKeysWithValues: providers.map { ($0.code, $0) })
    }()

    /// Validates a saved route endpoint and ensures this handler has a decoder
    /// for its mode and provider.
    static func request(mode: String, providerCode: String, apiURL: String) -> NativeTransitETARequest? {
        guard mode == "bus",
              registered[providerCode] != nil,
              let url = URL(string: apiURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return nil
        }
        return NativeTransitETARequest(url: url, mode: mode, providerCode: providerCode)
    }

    /// Supports alarms saved before route-specific API URLs were added.
    static func legacyRequest(providerCode: String, stopID: String, routeNumber: String) -> NativeTransitETARequest? {
        guard let provider = registered[providerCode],
              let url = provider.legacyETAURL(stopID: stopID, routeNumber: routeNumber) else {
            return nil
        }
        return NativeTransitETARequest(url: url, mode: "bus", providerCode: providerCode)
    }

    /// Routes response decoding through the operator implementation, returning
    /// no arrivals if the provider code is not registered.
    static func arrivalDates(
        from data: Data,
        providerCode: String,
        matching routeNumbers: Set<String>
    ) -> [Date] {
        registered[providerCode]?.arrivalDates(from: data, matching: routeNumbers) ?? []
    }
}

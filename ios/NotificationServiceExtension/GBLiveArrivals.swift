import Foundation
import SQLite3

/// Live arrivals for a GB stop, ported from the app's GbBodsProvider so the
/// notification extension can run without Flutter. London stops (ATCO codes
/// starting 490) use TfL's arrivals API; everywhere else uses the BODS SIRI-VM
/// vehicle feed, matching each bus to its GTFS trip to estimate when it reaches
/// the stop. Kept small for the extension's memory limit: a streaming XML
/// parser, a bounded number of requests, and one read-only SQLite connection.
struct GBLiveArrivals {
    /// Live arrival times, and the GTFS trips a feed shows as running or
    /// already past the stop, which the timetable fallback should skip.
    struct Result {
        var arrivals: [Date] = []
        var liveTripIDs: Set<String> = []
    }

    let databaseURL: URL
    let stopID: String
    /// Route number to the destination saved with the alarm (English name),
    /// or nil to accept any destination.
    let routes: [String: String?]
    let timeZone: TimeZone
    /// The BODS key, supplied at build time in the extension's Info.plist.
    var apiKey: String? = Bundle.main.object(forInfoDictionaryKey: "UKBodsAPIKey") as? String

    private static let maxConcurrentRequests = 3
    private static let pausedUntilKey = "bods_requests_paused_until"
    /// London stops' ATCO codes start with this; TfL's API covers them.
    private static let londonStopPrefix = "490"

    func fetch() async -> Result {
        if stopID.hasPrefix(Self.londonStopPrefix) {
            return await fetchTfL()
        }
        return await fetchBods()
    }

    // MARK: TfL (London)

    private func fetchTfL() async -> Result {
        let session = Self.session()
        defer { session.finishTasksAndInvalidate() }
        let routeNumbers = Array(routes.keys)
        let now = Date()
        let arrivals = await Self.boundedMap(routeNumbers) { route -> [Date] in
            guard let encodedRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://api.tfl.gov.uk/Line/\(encodedRoute)/Arrivals/\(stopID)"),
                  let data = await Self.get(url, session: session),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return rows.compactMap { row -> Date? in
                guard (row["lineName"] as? String) == route,
                      matchesDestination(row["destinationName"] as? String, route: route, tolerant: true),
                      let seconds = (row["timeToStation"] as? NSNumber)?.doubleValue else {
                    return nil
                }
                return now.addingTimeInterval(seconds)
            }
        }
        return Result(arrivals: arrivals.flatMap { $0 })
    }

    // MARK: BODS (SIRI-VM vehicle locations)

    private func fetchBods() async -> Result {
        guard let apiKey, !apiKey.isEmpty,
              !Self.requestsPaused() else {
            return Result()
        }
        guard let database = Self.openDatabase(databaseURL) else { return Result() }
        defer { sqlite3_close(database) }

        // Look up each route's operator first; the database isn't touched
        // while the feed requests run.
        var operators: [(route: String, noc: String)] = []
        for route in routes.keys.sorted() {
            if let noc = Self.operatorCode(database: database, stopID: stopID, route: route) {
                operators.append((route, noc))
            }
        }

        let session = Self.session()
        defer { session.finishTasksAndInvalidate() }
        let feeds = await Self.boundedMap(operators) { item -> (route: String, noc: String, vehicles: [Vehicle]) in
            let vehicles = await Self.vehicleFeed(route: item.route, noc: item.noc, apiKey: apiKey, session: session)
            return (item.route, item.noc, vehicles)
        }

        var result = Result()
        let now = Date()
        for feed in feeds {
            for vehicle in feed.vehicles where matchesDestination(vehicle.destinationName, route: feed.route) {
                guard let match = estimate(
                    vehicle: vehicle,
                    route: feed.route,
                    noc: feed.noc,
                    database: database
                ) else { continue }
                result.liveTripIDs.insert(match.tripID)
                if let seconds = match.secondsUntilArrival {
                    result.arrivals.append(now.addingTimeInterval(TimeInterval(seconds)))
                }
            }
        }
        return result
    }

    /// One vehicle's fields from the SIRI-VM feed.
    struct Vehicle {
        var originRef: String?
        var originAimedDeparture: Date?
        var destinationName: String?
        var latitude: Double?
        var longitude: Double?
    }

    /// The trip a vehicle is running, and seconds until it reaches the stop,
    /// or nil seconds if it has already gone past.
    private func estimate(
        vehicle: Vehicle,
        route: String,
        noc: String,
        database: OpaquePointer
    ) -> (tripID: String, secondsUntilArrival: Int?)? {
        guard let originRef = vehicle.originRef,
              let aimedDeparture = vehicle.originAimedDeparture,
              let latitude = vehicle.latitude,
              let longitude = vehicle.longitude else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: aimedDeparture)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let weekday = parts.weekday, let hour = parts.hour,
              let minute = parts.minute, let second = parts.second else { return nil }
        let serviceDate = String(format: "%04d%02d%02d", year, month, day)
        let weekdayColumn = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][weekday - 1]
        let aimedSeconds = hour * 3600 + minute * 60 + second

        // Match the vehicle's origin and departure to an active trip that also
        // serves this stop, as the app does.
        let candidatesSQL = """
            SELECT gt.trip_id, first.departure_time
            FROM gtfs_trips gt
            INNER JOIN gtfs_routes gr ON gr.route_id = gt.route_id
            INNER JOIN gtfs_agencies ga ON ga.agency_id = gr.agency_id
            INNER JOIN gtfs_stop_times first ON first.trip_id = gt.trip_id
              AND first.stop_sequence = (
                SELECT MIN(first2.stop_sequence) FROM gtfs_stop_times first2
                WHERE first2.trip_id = gt.trip_id
              )
            WHERE gr.route_short_name = ? AND ga.agency_noc = ?
              AND first.stop_id = ?
              AND EXISTS (
                SELECT 1 FROM gtfs_stop_times target
                WHERE target.trip_id = gt.trip_id AND target.stop_id = ?
              )
              AND (
                EXISTS (
                  SELECT 1 FROM gtfs_calendar gc
                  WHERE gc.service_id = gt.service_id
                    AND gc.start_date <= ? AND gc.end_date >= ?
                    AND gc.\(weekdayColumn) = 1
                )
                OR EXISTS (
                  SELECT 1 FROM gtfs_calendar_dates gcd
                  WHERE gcd.service_id = gt.service_id
                    AND gcd.date = ? AND gcd.exception_type = 1
                )
              )
              AND NOT EXISTS (
                SELECT 1 FROM gtfs_calendar_dates excluded
                WHERE excluded.service_id = gt.service_id
                  AND excluded.date = ? AND excluded.exception_type = 2
              )
            """
        var bestTrip: String?
        var bestDelta = Int.max
        Self.query(database, candidatesSQL, [route, noc, originRef, stopID, serviceDate, serviceDate, serviceDate, serviceDate]) { row in
            guard let tripID = Self.text(row, 0),
                  let scheduled = Self.gtfsSeconds(Self.text(row, 1)) else { return }
            // Compare time of day, allowing GTFS times past 24:00.
            let timeOfDay = scheduled % 86400
            var delta = abs(timeOfDay - aimedSeconds)
            delta = min(delta, 86400 - delta)
            if delta < bestDelta {
                bestDelta = delta
                bestTrip = tripID
            }
        }
        // The aimed departure should pin the trip closely; reject weak matches.
        guard let tripID = bestTrip, bestDelta <= 10 * 60 else { return nil }

        struct StopTime {
            let stopID: String
            let arrival: Int?
            let departure: Int?
            let latitude: Double
            let longitude: Double
        }
        var stops: [StopTime] = []
        let stopsSQL = """
            SELECT st.arrival_time, st.departure_time, st.stop_id, s.stop_lat, s.stop_lon
            FROM gtfs_stop_times st
            INNER JOIN gtfs_stops s ON s.stop_id = st.stop_id
            WHERE st.trip_id = ?
            ORDER BY st.stop_sequence
            """
        Self.query(database, stopsSQL, [tripID]) { row in
            guard let stop = Self.text(row, 2) else { return }
            stops.append(StopTime(
                stopID: stop,
                arrival: Self.gtfsSeconds(Self.text(row, 0)),
                departure: Self.gtfsSeconds(Self.text(row, 1)),
                latitude: sqlite3_column_double(row, 3),
                longitude: sqlite3_column_double(row, 4)
            ))
        }
        guard stops.count >= 2,
              let targetIndex = stops.firstIndex(where: { $0.stopID == stopID }),
              targetIndex > 0 else { return nil }

        // Find the consecutive stop pair closest to the bus, then interpolate
        // the remaining time across that pair.
        var bestPair = -1
        var bestDistance = Double.infinity
        var bestFraction = 0.0
        for index in 0..<(stops.count - 1) {
            let projection = Self.project(
                latitude: latitude,
                longitude: longitude,
                from: (stops[index].latitude, stops[index].longitude),
                to: (stops[index + 1].latitude, stops[index + 1].longitude)
            )
            if projection.distance < bestDistance {
                bestDistance = projection.distance
                bestFraction = projection.fraction
                bestPair = index
            }
        }
        guard bestPair >= 0 else { return nil }
        // The bus has passed the stop if the closest pair ends at or before it.
        if bestPair >= targetIndex { return (tripID, nil) }

        guard let fromDeparture = stops[bestPair].departure,
              let nextArrival = stops[bestPair + 1].arrival,
              let targetArrival = stops[targetIndex].arrival else { return nil }
        let pairDuration = max(0, nextArrival - fromDeparture)
        let remainingToNext = min(pairDuration, Int(((1 - bestFraction) * Double(pairDuration)).rounded()))
        let afterNext = max(0, targetArrival - nextArrival)
        return (tripID, remainingToNext + afterNext)
    }

    /// Distance from a point to a stop pair's segment, and how far along the
    /// segment its closest point is (0 to 1), on a local flat projection.
    static func project(
        latitude: Double,
        longitude: Double,
        from: (Double, Double),
        to: (Double, Double)
    ) -> (distance: Double, fraction: Double) {
        let metersPerDegree = 111_320.0
        let meanLatitude = (from.0 + to.0 + latitude) / 3
        let longitudeScale = cos(meanLatitude * .pi / 180)
        let bx = (to.1 - from.1) * metersPerDegree * longitudeScale
        let by = (to.0 - from.0) * metersPerDegree
        let px = (longitude - from.1) * metersPerDegree * longitudeScale
        let py = (latitude - from.0) * metersPerDegree
        let lengthSquared = bx * bx + by * by
        let fraction = lengthSquared == 0 ? 0 : min(1, max(0, (px * bx + py * by) / lengthSquared))
        let dx = px - fraction * bx
        let dy = py - fraction * by
        return ((dx * dx + dy * dy).squareRoot(), fraction)
    }

    // MARK: Feed requests

    private static func vehicleFeed(
        route: String,
        noc: String,
        apiKey: String,
        session: URLSession
    ) async -> [Vehicle] {
        var components = URLComponents(string: "https://data.bus-data.dft.gov.uk/api/v1/datafeed/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "lineRef", value: route),
            URLQueryItem(name: "operatorRef", value: noc),
        ]
        guard let url = components.url,
              let data = await get(url, session: session, pausesBods: true) else { return [] }
        return SiriVehicleParser.vehicles(in: data)
    }

    /// GETs [url], returning the body on HTTP 200. With [pausesBods], a 401 or
    /// 403 (key refused) pauses BODS calls for an hour, and a 429 for the
    /// server's Retry-After or 5 minutes, shared with later extension runs.
    private static func get(_ url: URL, session: URLSession, pausesBods: Bool = false) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if pausesBods {
            switch http.statusCode {
            case 401, 403:
                pauseRequests(for: 3600)
            case 429:
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                pauseRequests(for: min(3600, max(30, retryAfter ?? 300)))
            default:
                break
            }
        }
        return http.statusCode == 200 ? data : nil
    }

    private static func requestsPaused() -> Bool {
        let pausedUntil = UserDefaults(suiteName: AppGroup.identifier)?.double(forKey: pausedUntilKey) ?? 0
        return Date().timeIntervalSince1970 < pausedUntil
    }

    private static func pauseRequests(for seconds: TimeInterval) {
        UserDefaults(suiteName: AppGroup.identifier)?
            .set(Date().timeIntervalSince1970 + seconds, forKey: pausedUntilKey)
    }

    /// An ephemeral session with no URL cache, so responses aren't kept in
    /// the extension's limited memory.
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = maxConcurrentRequests
        return URLSession(configuration: configuration)
    }

    /// Maps [items] concurrently, at most [maxConcurrentRequests] at a time,
    /// keeping the input order.
    private static func boundedMap<Item, Output>(
        _ items: [Item],
        _ transform: @escaping (Item) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(maxConcurrentRequests, items.count) {
                let index = next
                group.addTask { (index, await transform(items[index])) }
                next += 1
            }
            while let (index, output) = await group.next() {
                results[index] = output
                if next < items.count {
                    let index = next
                    group.addTask { (index, await transform(items[index])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: Matching helpers

    /// BODS and TfL use underscores for spaces in destination names; compare
    /// the cleaned name with the destination saved on the alarm. [tolerant]
    /// (for TfL, whose names are often shorter or longer than the GTFS ones,
    /// such as "Oxford Circus" for "Oxford Circus, Regent Street") also
    /// accepts either name containing the other, ignoring case.
    private func matchesDestination(_ name: String?, route: String, tolerant: Bool = false) -> Bool {
        guard let expected = routes[route] ?? nil, !expected.isEmpty else { return true }
        let cleaned = (name ?? "")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if cleaned == expected { return true }
        guard tolerant, !cleaned.isEmpty else { return false }
        let live = cleaned.lowercased()
        let saved = expected.lowercased()
        return live.contains(saved) || saved.contains(live)
    }

    // MARK: SQLite

    static func openDatabase(_ url: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        sqlite3_exec(database, "PRAGMA cache_size=-512; PRAGMA mmap_size=0;", nil, nil, nil)
        return database
    }

    private static func operatorCode(database: OpaquePointer, stopID: String, route: String) -> String? {
        let sql = """
            SELECT DISTINCT ga.agency_noc
            FROM gtfs_stop_times gst
            INNER JOIN gtfs_trips gt ON gst.trip_id = gt.trip_id
            INNER JOIN gtfs_routes gr ON gt.route_id = gr.route_id
            INNER JOIN gtfs_agencies ga ON gr.agency_id = ga.agency_id
            WHERE gst.stop_id = ? AND gr.route_short_name = ?
            LIMIT 1
            """
        var noc: String?
        query(database, sql, [stopID, route]) { row in noc = text(row, 0) }
        return (noc?.isEmpty ?? true) ? nil : noc
    }

    /// Runs [sql] with text [bindings], calling [onRow] for each result row.
    static func query(
        _ database: OpaquePointer,
        _ sql: String,
        _ bindings: [String],
        onRow: (OpaquePointer) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            onRow(statement)
        }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(row, column) else { return nil }
        return String(cString: pointer)
    }

    /// Seconds since midnight for a GTFS "HH:MM:SS" time, which can pass 24:00.
    static func gtfsSeconds(_ value: String?) -> Int? {
        let parts = (value ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

/// Streams a SIRI-VM response, keeping only the few fields needed for each
/// VehicleActivity rather than building the whole document in memory.
final class SiriVehicleParser: NSObject, XMLParserDelegate {
    private var vehicles: [GBLiveArrivals.Vehicle] = []
    private var current: GBLiveArrivals.Vehicle?
    private var inLocation = false
    private var text = ""

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func vehicles(in data: Data) -> [GBLiveArrivals.Vehicle] {
        let delegate = SiriVehicleParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        // Skip activities missing what the trip match needs.
        return delegate.vehicles.filter {
            $0.originRef != nil && $0.originAimedDeparture != nil &&
                $0.latitude != nil && $0.longitude != nil
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "VehicleActivity": current = GBLiveArrivals.Vehicle()
        case "VehicleLocation": inLocation = true
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch elementName {
        case "VehicleActivity":
            if let current { vehicles.append(current) }
            current = nil
        case "VehicleLocation":
            inLocation = false
        case "OriginRef":
            current?.originRef = value
        case "OriginAimedDepartureTime":
            current?.originAimedDeparture = Self.isoFormatter.date(from: value)
                ?? Self.fractionalFormatter.date(from: value)
        case "DestinationName":
            current?.destinationName = value
        case "Latitude" where inLocation:
            current?.latitude = Double(value)
        case "Longitude" where inLocation:
            current?.longitude = Double(value)
        default:
            break
        }
    }
}

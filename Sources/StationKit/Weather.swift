import Foundation

/// National Weather Service (api.weather.gov): free, no key, but a
/// User-Agent with contact info is required.
actor Weather {
    struct Current {
        let temperatureF: Int?
        let conditions: String?
    }

    struct Period {
        let name: String          // "Tonight", "Monday", …
        let temperature: Int
        let isDaytime: Bool
        let shortForecast: String
        let detailedForecast: String
    }

    private let config: StationConfig
    private var points: (forecast: URL, forecastHourly: URL, stations: URL, city: String)?
    private var station: URL?
    private var cachedCurrent: (Date, Current)?

    init(config: StationConfig) { self.config = config }

    var city: String? { points?.city }

    func current() async throws -> Current {
        if let (at, value) = cachedCurrent, Date().timeIntervalSince(at) < 600 { return value }
        let p = try await resolvePoints()
        var temperature: Int?
        var conditions: String?
        if let station = try await nearestStation(p.stations) {
            let obs = try await json(station.appendingPathComponent("observations/latest"))
            let props = obs["properties"] as? [String: Any]
            if let c = (props?["temperature"] as? [String: Any])?["value"] as? Double {
                temperature = Int((c * 9 / 5 + 32).rounded())
            }
            conditions = (props?["textDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        // Stations often report a null temperature; the hourly forecast is the fallback.
        if temperature == nil || conditions == nil, let hour = try await periods(p.forecastHourly).first {
            temperature = temperature ?? hour.temperature
            conditions = conditions ?? hour.shortForecast
        }
        let value = Current(temperatureF: temperature, conditions: conditions)
        cachedCurrent = (Date(), value)
        return value
    }

    func forecast() async throws -> [Period] {
        try await periods(try await resolvePoints().forecast)
    }

    private func resolvePoints() async throws -> (forecast: URL, forecastHourly: URL, stations: URL, city: String) {
        if let points { return points }
        let url = URL(string: String(format: "https://api.weather.gov/points/%.4f,%.4f",
                                     config.latitude, config.longitude))!
        let props = try await json(url)["properties"] as? [String: Any] ?? [:]
        guard let f = (props["forecast"] as? String).flatMap(URL.init(string:)),
              let fh = (props["forecastHourly"] as? String).flatMap(URL.init(string:)),
              let s = (props["observationStations"] as? String).flatMap(URL.init(string:)) else {
            throw DirectorError("NWS points lookup returned no forecast URLs")
        }
        let city = ((props["relativeLocation"] as? [String: Any])?["properties"] as? [String: Any])?["city"] as? String
        let resolved = (f, fh, s, city ?? "")
        points = resolved
        return resolved
    }

    private func nearestStation(_ list: URL) async throws -> URL? {
        if let station { return station }
        let features = try await json(list)["features"] as? [[String: Any]]
        station = (features?.first?["id"] as? String).flatMap(URL.init(string:))
        return station
    }

    private func periods(_ url: URL) async throws -> [Period] {
        let props = try await json(url)["properties"] as? [String: Any]
        return (props?["periods"] as? [[String: Any]] ?? []).compactMap { p in
            guard let temperature = p["temperature"] as? Int else { return nil }
            return Period(name: p["name"] as? String ?? "",
                          temperature: temperature,
                          isDaytime: p["isDaytime"] as? Bool ?? true,
                          shortForecast: p["shortForecast"] as? String ?? "",
                          detailedForecast: p["detailedForecast"] as? String ?? "")
        }
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(config.weatherUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DirectorError("NWS \(url.path): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

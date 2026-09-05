import Foundation
import FoundationModels

struct WeatherLookup: Identifiable, Sendable {
    let id = UUID()
    let location: String
    let temperature: Double
    let observedAt: String
}

actor WeatherToolBudget {
    private var calls = 0
    func reset() { calls = 0 }
    func take() throws {
        guard calls < 6 else { throw WeatherError.tooManyLookups }
        calls += 1
    }
}

enum WeatherError: LocalizedError {
    case invalidCity, noLocation, unavailable, tooManyLookups
    var errorDescription: String? {
        switch self {
        case .invalidCity: "Please provide a city name and, if needed, its two-letter country code."
        case .noLocation: "No matching location was found. Ask for a more specific city."
        case .unavailable: "The live weather service is unavailable. Do not invent a weather report."
        case .tooManyLookups: "This turn has reached its six-weather-lookup limit."
        }
    }
}

/// The framework invokes this Tool from a model-generated function call. The
/// app—not the model—owns the two fixed HTTPS destinations. No GPS or API key.
struct WeatherCheckTool: Tool {
    let name = "weather_check"
    let description = "Check live current weather and a three-day forecast for a named city. Always call this for weather questions; never guess live weather. Supply a country code to disambiguate cities. Temperatures are Celsius."
    let budget: WeatherToolBudget
    let onLookup: @Sendable (WeatherLookup) async -> Void

    @Generable
    struct Arguments {
        @Guide(description: "City name only, for example Singapore, London, or Ho Chi Minh City.")
        var city: String
        @Guide(description: "Optional ISO 3166-1 alpha-2 country code, for example SG, GB, or VN.")
        var countryCode: String?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        try await budget.take()
        let city = arguments.city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 160).contains(city.count), !city.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WeatherError.invalidCity
        }
        var query = [URLQueryItem(name: "name", value: city), .init(name: "count", value: "1"), .init(name: "language", value: "en")]
        if let country = arguments.countryCode, !country.isEmpty {
            guard country.utf8.count == 2, country.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) }) else {
                throw WeatherError.invalidCity
            }
            query.append(.init(name: "countryCode", value: country.uppercased()))
        }
        let locations: Locations = try await fetch(host: "geocoding-api.open-meteo.com", path: "/v1/search", query: query)
        guard let place = locations.results?.first else { throw WeatherError.noLocation }
        let weather: Forecast = try await fetch(host: "api.open-meteo.com", path: "/v1/forecast", query: [
            .init(name: "latitude", value: String(place.latitude)), .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "forecast_days", value: "3"), .init(name: "timezone", value: "auto"),
        ])
        let location = [place.name, place.admin1, place.country].compactMap { $0 }.joined(separator: ", ")
        let report = Report(source: "Open-Meteo (https://open-meteo.com/), locations by GeoNames", location: location,
                            timezone: weather.timezone, current: weather.current, current_units: weather.current_units,
                            daily: weather.daily, daily_units: weather.daily_units)
        let encoded = try JSONEncoder().encode(report)
        await onLookup(WeatherLookup(location: location, temperature: weather.current.temperature_2m, observedAt: weather.current.time))
        return String(decoding: encoded, as: UTF8.self)
    }

    private func fetch<Value: Decodable>(host: String, path: String, query: [URLQueryItem]) async throws -> Value {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw WeatherError.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == host else {
            throw WeatherError.unavailable
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 262_144 else { throw WeatherError.unavailable }
            data.append(byte)
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { throw WeatherError.unavailable }
        return value
    }

    private struct Locations: Decodable {
        struct Place: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
            let country: String?
        }
        let results: [Place]?
    }
    private struct Forecast: Decodable {
        let timezone: String
        let current: Current
        let current_units: [String: String]
        let daily: Daily
        let daily_units: [String: String]
    }
    private struct Current: Codable {
        let time: String
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Double
        let precipitation: Double
        let weather_code: Int
        let wind_speed_10m: Double
    }
    private struct Daily: Codable {
        let time: [String]
        let weather_code: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Double?]
    }
    private struct Report: Encodable {
        let source: String
        let location: String
        let timezone: String
        let current: Current
        let current_units: [String: String]
        let daily: Daily
        let daily_units: [String: String]
    }
}

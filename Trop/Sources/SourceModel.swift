//
// SourceModel.swift
// Trop
//
// The services Music+ can read besides YouTube Music. A service either hands
// over an audio URL we can feed to mpv, or only a catalog that has to be
// matched onto YouTube. The badge in the UI always says which happened.
//

import Foundation

enum SourceID: String, CaseIterable, Codable, Sendable, Identifiable {
    case youtube
    case soundcloud
    case yandex
    case spotify
    case vk
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: return "YouTube Music"
        case .soundcloud: return "SoundCloud"
        case .yandex: return "Яндекс Музыка"
        case .spotify: return "Spotify"
        case .vk: return "VK Музыка"
        case .appleMusic: return "Apple Music"
        }
    }

    /// Shown under the toggle. Every caveat here is real, not legal boilerplate.
    var note: String? {
        switch self {
        case .yandex:
            return "Нужен Яндекс Плюс: без подписки сервис отдаёт только каталог и 30-секундные превью."
        case .spotify:
            return "Spotify не отдаёт аудиопоток сторонним клиентам. Каталог, импорт и поиск — да, звук — с YouTube."
        case .vk:
            return "VK закрыл audio.* для сторонних приложений. Доступен импорт списков треков, не воспроизведение."
        case .appleMusic:
            return "Нужна подписка Apple Music. Играет системный плеер MusicKit, а не наш mpv."
        case .soundcloud, .youtube:
            return nil
        }
    }

    /// True when the service can hand over a URL mpv plays directly.
    var hasNativeStream: Bool { self == .soundcloud || self == .yandex }

    /// Services with a working implementation in this build.
    var isAvailable: Bool { self == .youtube || self == .soundcloud || self == .yandex }
}

/// One row from any service, normalised. Kept free of app types so the source
/// files stay testable on their own.
struct SourceTrack: Sendable, Hashable, Identifiable {
    let source: SourceID
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Int
    let artwork: String?
    let isExplicit: Bool

    init(
        source: SourceID,
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: Int = 0,
        artwork: String? = nil,
        isExplicit: Bool = false
    ) {
        self.source = source
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.isExplicit = isExplicit
    }

    /// The id used everywhere else in the app. The prefix keeps a SoundCloud
    /// numeric id from ever colliding with a YouTube one.
    var playbackKey: String { "\(source.rawValue):\(id)" }
}

/// A resolved audio URL, plus the few facts PlaybackResult needs.
struct NativeStream: Sendable, Hashable {
    let url: String
    let mimeType: String
    let bitrate: Int
    let expiresInSeconds: Int
    let title: String?
    let author: String?
    let duration: Int?

    init(
        url: String,
        mimeType: String = "audio/mpeg",
        bitrate: Int = 128,
        expiresInSeconds: Int = 3600,
        title: String? = nil,
        author: String? = nil,
        duration: Int? = nil
    ) {
        self.url = url
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.expiresInSeconds = expiresInSeconds
        self.title = title
        self.author = author
        self.duration = duration
    }
}

enum SourceError: LocalizedError {
    case notConfigured(SourceID)
    case needsPlus
    case unknownTrack(String)
    case badResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let id): return "\(id.title) не настроен"
        case .needsPlus: return "Нужен Яндекс Плюс"
        case .unknownTrack(let key): return "Поток не найден: \(key)"
        case .badResponse: return "Сервис ответил не тем, что ожидалось"
        case .http(let code): return "Сервис ответил \(code)"
        }
    }
}

protocol MusicSource: Sendable {
    var id: SourceID { get }
    /// True when the service has what it needs (token, key) to be used.
    var isConfigured: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [SourceTrack]
    func stream(for track: SourceTrack) async throws -> NativeStream
}

// MARK: - Shared HTTP helpers

enum SourceHTTP {
    static func json(
        _ url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.http(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func text(_ url: URL, headers: [String: String] = [:]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.badResponse
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func query(_ base: String, _ items: [(String, String)]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components?.url
    }

    /// Seconds from a millisecond duration, 0 when absent.
    static func seconds(_ milliseconds: Any?) -> Int {
        guard let value = (milliseconds as? NSNumber)?.doubleValue else { return 0 }
        return value > 10000 ? Int(value / 1000) : Int(value)
    }
}

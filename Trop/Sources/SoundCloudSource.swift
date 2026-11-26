//
// SoundCloudSource.swift
// Trop
//
// The only service here that streams on its own terms: public search and
// public transcodings need no account. Go+ and label-restricted tracks answer
// 401/403, and that is reported, never papered over.
//

import Foundation

struct SoundCloudSource: MusicSource {
    let id: SourceID = .soundcloud

    private static let clientKey = "sources.soundcloud.clientId"
    private static let api = "https://api-v2.soundcloud.com"

    var isConfigured: Bool { true }

    /// A client id is needed for every call; it is scraped from the public web
    /// player once and kept, because hard-coding one that rotates is worse.
    static var storedClientID: String? {
        let value = UserDefaults.standard.string(forKey: clientKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func setClientID(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: clientKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: clientKey)
        }
    }

    func search(_ query: String, limit: Int) async throws -> [SourceTrack] {
        let clientID = try await Self.clientID()
        guard let url = SourceHTTP.query(
            "\(Self.api)/search/tracks",
            [
                ("q", query),
                ("client_id", clientID),
                ("limit", String(max(1, min(limit, 50)))),
                ("linked_partitioning", "0"),
                ("app_locale", "en")
            ]
        ) else { throw SourceError.badResponse }

        let root = try await SourceHTTP.json(url)
        guard let dictionary = root as? [String: Any],
              let collection = dictionary["collection"] as? [[String: Any]] else {
            return []
        }
        return collection.compactMap(Self.track(from:))
    }

    func stream(for track: SourceTrack) async throws -> NativeStream {
        let clientID = try await Self.clientID()
        guard let url = URL(string: "\(Self.api)/tracks/\(track.id)/media/transcodings?client_id=\(clientID)") else {
            throw SourceError.badResponse
        }
        let root = try await SourceHTTP.json(url)
        guard let list = root as? [[String: Any]] else { throw SourceError.unknownTrack(track.playbackKey) }

        // Progressive mp3 first: it seeks instantly. HLS is the fallback and
        // mpv plays it as well, it just buffers more.
        let progressive = list.first { ($0["is_legacy_transcoding"] as? Bool) == true
            && (($0["format"] as? [String: Any])?["protocol"] as? String) == "progressive" }
        let hls = list.first { (($0["format"] as? [String: Any])?["protocol"] as? String) == "hls" }
        guard let chosen = progressive ?? hls ?? list.first,
              let transcoding = chosen["url"] as? String else {
            throw SourceError.needsPlus
        }

        guard let resolved = SourceHTTP.query(transcoding, [("client_id", clientID)]) else {
            throw SourceError.badResponse
        }
        let payload = try await SourceHTTP.json(resolved)
        guard let dictionary = payload as? [String: Any], let stream = dictionary["url"] as? String else {
            throw SourceError.badResponse
        }
        let mime = (chosen["format"] as? [String: Any])?["mime_type"] as? String ?? "audio/mpeg"
        return NativeStream(
            url: stream,
            mimeType: mime,
            bitrate: 128,
            expiresInSeconds: 3600,
            title: track.title,
            author: track.artist,
            duration: track.duration
        )
    }

    // MARK: - Client id

    private static let fallbackClientID = "KKzJxmw11tYpCs6T24P4uUYhqmjalG6M"

    static func clientID() async throws -> String {
        if let stored = storedClientID { return stored }
        if let scraped = try? await scrapeClientID(), !scraped.isEmpty {
            setClientID(scraped)
            return scraped
        }
        // Last resort: a known public web-player id. It rotates with their
        // deploys, which is why the scrape above comes first.
        return fallbackClientID
    }

    private static func scrapeClientID() async throws -> String {
        let html = try await SourceHTTP.text(URL(string: "https://soundcloud.com/")!)
        guard let scriptRange = html.range(of: "https://a-v2.sndcdn.com/assets/", options: .backwards),
              let endQuote = html[scriptRange.lowerBound...].firstIndex(of: "\"") else {
            throw SourceError.badResponse
        }
        let scriptURL = String(html[scriptRange.lowerBound..<endQuote])
        guard let url = URL(string: scriptURL) else { throw SourceError.badResponse }
        let script = try await SourceHTTP.text(url)

        guard let start = script.range(of: "client_id:\"") else { throw SourceError.badResponse }
        let rest = script[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { throw SourceError.badResponse }
        return String(rest[..<end])
    }

    // MARK: - Parsing

    static func track(from dictionary: [String: Any]) -> SourceTrack? {
        guard let identifier = dictionary["id"] as? NSNumber else { return nil }
        let title = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespaces)
        guard let title, !title.isEmpty else { return nil }

        let artist = (dictionary["user"] as? [String: Any])?["username"] as? String
            ?? (dictionary["publisher_metadata"] as? [String: Any])?["artist"] as? String
            ?? "SoundCloud"

        var artwork = dictionary["artwork_url"] as? String
        if artwork == nil {
            artwork = (dictionary["user"] as? [String: Any])?["avatar_url"] as? String
        }
        let large = artwork?.replacingOccurrences(of: "-large", with: "-t500x500")

        let policy = dictionary["policy"] as? String
        let downloadable = false

        return SourceTrack(
            source: .soundcloud,
            id: identifier.stringValue,
            title: title,
            artist: artist,
            album: (dictionary["publisher_metadata"] as? [String: Any])?["album_title"] as? String,
            duration: SourceHTTP.seconds(dictionary["full_duration"] ?? dictionary["duration"]),
            artwork: large,
            isExplicit: (dictionary["publisher_metadata"] as? [String: Any])?["explicit"] as? Bool
                ?? downloadable
                || policy == "BLOCK"
        )
    }
}

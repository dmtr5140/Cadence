//
// YandexSource.swift
// Trop
//
// Yandex Music through the official mobile API. The catalog is readable with
// any token; the audio URL is only handed out to a Plus subscription, and the
// app says so instead of pretending the track is broken.
//

import CryptoKit
import Foundation

struct YandexSource: MusicSource {
    let id: SourceID = .yandex

    private static let tokenKey = "sources.yandex.token"
    private static let api = "https://api.music.yandex.net"
    /// The community-known salt for the download-info signature. It has been
    /// stable for years; if it ever changes, streams answer 403 and the UI says
    /// so rather than failing silently.
    private static let salt = "XGRlBW9FXlekgbPrRHuSiA"

    var isConfigured: Bool { Self.token != nil }

    static var token: String? {
        let value = UserDefaults.standard.string(forKey: tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func setToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: tokenKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
        }
    }

    func search(_ query: String, limit: Int) async throws -> [SourceTrack] {
        guard let token = Self.token else { throw SourceError.notConfigured(.yandex) }
        guard let url = SourceHTTP.query(
            "\(Self.api)/search",
            [
                ("text", query),
                ("type", "all"),
                ("page", "0"),
                ("nocorrect", "false")
            ]
        ) else { throw SourceError.badResponse }

        let root = try await SourceHTTP.json(url, headers: ["Authorization": "OAuth \(token)"])
        guard let dictionary = root as? [String: Any] else { throw SourceError.badResponse }
        let result = (dictionary["result"] as? [String: Any])
        let tracks = ((result?["tracks"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return tracks.prefix(limit).compactMap(Self.track(from:))
    }

    func stream(for track: SourceTrack) async throws -> NativeStream {
        guard let token = Self.token else { throw SourceError.notConfigured(.yandex) }
        guard let url = URL(string: "\(Self.api)/tracks/\(track.id)/download-info") else {
            throw SourceError.badResponse
        }

        let root: Any
        do {
            root = try await SourceHTTP.json(url, headers: ["Authorization": "OAuth \(token)"])
        } catch SourceError.http(let code) where code == 401 || code == 403 || code == 402 {
            // Yandex answers 4xx on this exact endpoint for accounts without Plus.
            throw SourceError.needsPlus
        }

        guard let dictionary = root as? [String: Any],
              let infos = dictionary["result"] as? [[String: Any]] else {
            throw SourceError.needsPlus
        }
        let mp3 = infos.filter { ($0["codec"] as? String) == "mp3" }
        let chosen = mp3.first { ($0["bitrateInKbps"] as? NSNumber)?.intValue == 320 }
            ?? mp3.last
            ?? infos.first
        guard let info = chosen, let link = info["downloadInfoUrl"] as? String,
              let infoURL = URL(string: link) else {
            throw SourceError.needsPlus
        }

        let xml = try await SourceHTTP.text(infoURL)
        guard let host = Self.value(of: "host", in: xml),
              let path = Self.value(of: "path", in: xml),
              let timestamp = Self.value(of: "ts", in: xml),
              let signature = Self.value(of: "s", in: xml) else {
            throw SourceError.badResponse
        }

        let sign = Self.md5(Self.salt + path + signature)
        let relative = path.hasPrefix("/") ? path : "/" + path
        let stream = "https://\(host)/get-mp3/\(sign)/\(timestamp)\(relative)"
        let bitrate = (info["bitrateInKbps"] as? NSNumber)?.intValue ?? 192
        return NativeStream(
            url: stream,
            mimeType: "audio/mpeg",
            bitrate: bitrate,
            expiresInSeconds: 3600,
            title: track.title,
            author: track.artist,
            duration: track.duration
        )
    }

    // MARK: - Parsing

    static func track(from dictionary: [String: Any]) -> SourceTrack? {
        guard let identifier = dictionary["id"] else { return nil }
        let identifierString: String
        if let number = identifier as? NSNumber {
            identifierString = number.stringValue
        } else if let text = identifier as? String {
            identifierString = text
        } else {
            return nil
        }

        var title = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty { return nil }

        let artists = ((dictionary["artists"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ")
        if title.hasSuffix(" (") || title.isEmpty { title = title.trimmingCharacters(in: .whitespaces) }

        let album = ((dictionary["albums"] as? [[String: Any]]) ?? []).first
        var artwork: String?
        if let cover = album?["coverUri"] as? String {
            artwork = "https://" + cover.replacingOccurrences(of: "%%", with: "600x600")
        }

        return SourceTrack(
            source: .yandex,
            id: identifierString,
            title: title,
            artist: artists.isEmpty ? "Яндекс Музыка" : artists,
            album: album?["title"] as? String,
            duration: SourceHTTP.seconds(dictionary["durationMs"]),
            artwork: artwork,
            isExplicit: (dictionary["contentWarning"] as? String) == "explicit"
        )
    }

    // MARK: - Tiny XML

    private static func value(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>") else { return nil }
        guard let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        let value = String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Plus check

extension YandexSource {
    /// Reads the account status so the settings screen can say "Plus active"
    /// instead of making the listener guess why playback fails.
    static func accountStatus() async throws -> (name: String, hasPlus: Bool) {
        guard let token = token else { throw SourceError.notConfigured(.yandex) }
        guard let url = URL(string: "\(api)/account/status") else { throw SourceError.badResponse }
        let root = try await SourceHTTP.json(url, headers: ["Authorization": "OAuth \(token)"])
        guard let dictionary = root as? [String: Any],
              let result = dictionary["result"] as? [String: Any] else {
            throw SourceError.http(401)
        }
        let account = result["account"] as? [String: Any]
        let name = account?["displayName"] as? String
            ?? account?["login"] as? String
            ?? "Яндекс"
        let plus = (account?["plus"] as? Bool) ?? false
        return (name, plus)
    }
}

//
// NativeStreamTable.swift
// Trop
//
// The bridge between "this row is a SoundCloud track" and the mpv player,
// which only ever asks for a URL by id. PlaybackManager checks this table
// before it calls YouTube.
//

import Foundation
import SwiftyTube

actor NativeStreamTable {
    static let shared = NativeStreamTable()

    private var resolvers: [String: @Sendable () async throws -> NativeStream] = [:]

    func register(key: String, resolver: @escaping @Sendable () async throws -> NativeStream) {
        resolvers[key] = resolver
    }

    func forget(key: String) {
        resolvers.removeValue(forKey: key)
    }

    func canHandle(_ key: String) -> Bool {
        resolvers[key] != nil
    }

    func stream(for key: String) async throws -> NativeStream {
        guard let resolver = resolvers[key] else { throw SourceError.unknownTrack(key) }
        return try await resolver()
    }
}

extension NativeStream {
    /// Fits a native stream into the type the player already understands.
    /// `itag` 0 and no muxed URL: Yandex and SoundCloud hand over audio only.
    func playbackResult(key: String) -> PlaybackResult {
        PlaybackResult(
            streamUrl: url,
            itag: 0,
            mimeType: mimeType,
            bitrate: bitrate,
            audioQuality: "\(bitrate) kbps",
            videoId: key,
            title: title,
            author: author,
            duration: duration,
            expiresInSeconds: expiresInSeconds,
            clientName: key.split(separator: ":").first.map(String.init) ?? "native",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            muxedWidth: nil,
            muxedHeight: nil,
            loudnessDb: nil
        )
    }
}

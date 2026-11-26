//
// SourceFallback.swift
// Trop
//
// When YouTube refuses a track — region, age, deleted — the same song is looked
// up on the services that hand over their own stream. Nothing is swapped
// silently: Substitutions remembers where the sound came from, and the UI can
// say it out loud.
//

import Foundation
import Observation

@Observable
@MainActor
final class Substitutions {
    static let shared = Substitutions()

    private(set) var byVideoID: [String: SourceID] = [:]

    func note(_ source: SourceID, for videoId: String) {
        byVideoID[videoId] = source
    }

    func clear(_ videoId: String) {
        byVideoID.removeValue(forKey: videoId)
    }

    func source(for videoId: String?) -> SourceID? {
        guard let videoId else { return nil }
        return byVideoID[videoId]
    }
}

enum SourceFallback {
    struct Match {
        let key: String
        let stream: NativeStream
        let source: SourceID
    }

    /// Searches the enabled services that stream on their own and returns the
    /// closest row. Nil rather than a guess: a wrong song is worse than the
    /// original error.
    static func find(title: String, artist: String, duration: TimeInterval) async -> Match? {
        let wantedTitle = clean(title)
        let wantedArtist = clean(artist)
        guard !wantedTitle.isEmpty else { return nil }

        let providers: [any MusicSource] = await MainActor.run {
            SourceRegistry.shared.activeSources.filter { $0.isConfigured && $0.id.hasNativeStream }
        }
        guard !providers.isEmpty else { return nil }

        for provider in providers {
            let query = wantedArtist.isEmpty ? wantedTitle : "\(wantedArtist) \(wantedTitle)"
            guard let rows = try? await provider.search(query, limit: 25) else { continue }
            guard let best = bestMatch(rows, title: wantedTitle, artist: wantedArtist, duration: duration) else { continue }
            do {
                let stream = try await provider.stream(for: best)
                return Match(key: best.playbackKey, stream: stream, source: provider.id)
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Matching

    private static func bestMatch(
        _ rows: [SourceTrack],
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> SourceTrack? {
        var winner: (row: SourceTrack, score: Int)?
        for row in rows {
            let value = score(row, title: title, artist: artist, duration: duration)
            guard value > 0 else { continue }
            if winner == nil || value > winner!.score { winner = (row, value) }
        }
        guard let winner, winner.score >= 40 else { return nil }
        return winner.row
    }

    private static func score(
        _ row: SourceTrack,
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> Int {
        let rowTitle = clean(row.title)
        let rowArtist = clean(row.artist)

        var score = 0
        if rowTitle == title { score += 50 }
        else if rowTitle.contains(title) || title.contains(rowTitle) { score += 30 }
        else { return 0 }

        if !artist.isEmpty {
            if rowArtist == artist { score += 40 }
            else if rowArtist.contains(artist) || artist.contains(rowArtist) { score += 25 }
        }

        if duration > 1, row.duration > 0 {
            let delta = abs(Double(row.duration) - duration)
            if delta <= 2 { score += 30 }
            else if delta <= 5 { score += 15 }
            else if delta > 20 { score -= 25 }
        }

        // Karaoke and nightcore rows match the words but are a different recording.
        for junk in ["karaoke", "cover", "tribute", "sped up", "slowed", "nightcore", "8d"] {
            if rowTitle.contains(junk), !title.contains(junk) { score -= 20 }
        }
        return score
    }

    /// Lowercase, no bracketed suffixes, letters and digits only.
    private static func clean(_ text: String) -> String {
        var value = text.lowercased()
        for token in [" (official", " [official", " (audio", " [audio", " (video", " [video",
                      " (lyrics", " [lyrics", " (remaster", " [remaster", " feat.", " ft."] {
            if let range = value.range(of: token) { value = String(value[..<range.lowerBound]) }
        }
        value = value.replacingOccurrences(of: "ё", with: "е")

        var cleaned = ""
        cleaned.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").joined(separator: " ")
    }
}

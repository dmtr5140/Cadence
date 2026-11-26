//
// SourceRegistry.swift
// Trop
//
// Which services are on, and whether a search goes to all of them or to one.
//

import Foundation
import Observation

@Observable
@MainActor
final class SourceRegistry {
    static let shared = SourceRegistry()

    enum Mode: String, CaseIterable, Identifiable {
        case mixed
        case only

        var id: String { rawValue }
        var title: String { self == .mixed ? "Вперемешку" : "Только один" }
    }

    private static let enabledKey = "sources.enabled.v1"
    private static let modeKey = "sources.mode.v1"
    private static let onlyKey = "sources.only.v1"

    private let defaults = UserDefaults.standard

    private(set) var enabled: Set<SourceID>
    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// The one service used when `mode == .only`.
    var only: SourceID {
        didSet { defaults.set(only.rawValue, forKey: Self.onlyKey) }
    }

    let providers: [any MusicSource] = [SoundCloudSource(), YandexSource()]

    private init() {
        let raw = defaults.stringArray(forKey: Self.enabledKey) ?? []
        let stored = Set(raw.compactMap(SourceID.init(rawValue:)))
        enabled = stored.isEmpty ? [.soundcloud] : stored
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .mixed
        only = SourceID(rawValue: defaults.string(forKey: Self.onlyKey) ?? "") ?? .soundcloud
    }

    func isEnabled(_ id: SourceID) -> Bool {
        if id == .youtube { return true }
        return enabled.contains(id)
    }

    func setEnabled(_ id: SourceID, _ value: Bool) {
        guard id != .youtube else { return }
        if value { enabled.insert(id) } else { enabled.remove(id) }
        defaults.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
        if !enabled.isEmpty, !enabled.contains(only) {
            only = enabled.sorted { $0.rawValue < $1.rawValue }.first ?? .soundcloud
        }
    }

    func provider(_ id: SourceID) -> (any MusicSource)? {
        providers.first { $0.id == id }
    }

    /// Services actually used by a search right now.
    var activeSources: [any MusicSource] {
        let wanted: [SourceID] = mode == .only ? [only] : Array(enabled)
        return providers.filter { wanted.contains($0.id) }
    }

    /// Runs the search across the active services. One failure never sinks the
    /// rest: results already gathered are returned, and the failure is reported
    /// alongside them.
    /// One service's answer. A `Result` with an `Error` is not `Sendable`,
    /// so the failure travels as a message instead.
    private struct SourceOutcome: Sendable {
        let id: SourceID
        let tracks: [SourceTrack]
        let error: String?
    }

    func searchAll(_ query: String, limit: Int = 30) async -> (tracks: [SourceTrack], failures: [SourceID: String]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], [:]) }

        let sources = activeSources
        return await withTaskGroup(of: SourceOutcome.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let tracks = try await source.search(trimmed, limit: limit)
                        return SourceOutcome(id: source.id, tracks: tracks, error: nil)
                    } catch {
                        return SourceOutcome(id: source.id, tracks: [], error: error.localizedDescription)
                    }
                }
            }

            var buckets: [SourceID: [SourceTrack]] = [:]
            var failures: [SourceID: String] = [:]
            for await outcome in group {
                buckets[outcome.id] = outcome.tracks
                if let message = outcome.error { failures[outcome.id] = message }
            }

            // Interleave so the first screen is not one service's whole page.
            var merged: [SourceTrack] = []
            var index = 0
            while true {
                var added = false
                for source in sources {
                    let list = buckets[source.id] ?? []
                    if index < list.count {
                        merged.append(list[index])
                        added = true
                    }
                }
                if !added { break }
                index += 1
            }
            return (merged, failures)
        }
    }

    /// Teaches the playback layer how to fetch a native stream for this row.
    /// Called right before playing, so a rotated token is picked up on retry.
    func prepareNativePlayback(for tracks: [SourceTrack]) async {
        for track in tracks where track.source.hasNativeStream {
            guard let provider = provider(track.source) else { continue }
            await NativeStreamTable.shared.register(key: track.playbackKey) {
                try await provider.stream(for: track)
            }
        }
    }
}

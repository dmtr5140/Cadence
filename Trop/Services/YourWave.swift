import Foundation

@MainActor
private final class WaveRequestState {
    var id = UUID()
}

@MainActor
enum YourWave {
    enum Outcome {
        case started, noLikes, libraryUnavailable, cancelled
    }

    private static let request = WaveRequestState()

    static func play() async -> Outcome {
        let id = UUID()
        request.id = id
        let player = NowPlaying.shared
        let initialVideoID = player.videoId
        let initialQueue = player.queueSongs.map(\.videoId)
        func stillCurrent() -> Bool {
            !Task.isCancelled && request.id == id && player.videoId == initialVideoID
                && player.queueSongs.map(\.videoId) == initialQueue
        }

        let likes: [SongItem]
        do {
            likes = try await DatabaseService.shared.fetchAllLikedSongs().toSongItems()
        } catch {
            return stillCurrent() ? .libraryUnavailable : .cancelled
        }
        guard stillCurrent() else { return .cancelled }

        // Play counts decide the order of favourites: what the listener actually
        // plays comes first, everything else in the likes keeps its library order.
        let topOrder = await Self.playRank()
        guard stillCurrent() else { return .cancelled }

        let allowExplicit = !SettingsStore.shared.hideExplicit
        let eligible = likes
            .filter { $0.isAvailable && (allowExplicit || !$0.isExplicit) }
            .enumerated()
            .sorted { lhs, rhs in
                let l = topOrder[lhs.element.videoId] ?? Int.max
                let r = topOrder[rhs.element.videoId] ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
        guard !eligible.isEmpty else { return .noLikes }

        let seeds = Self.seeds(from: eligible)
        var lanes: [[SongItem]] = []
        if !seeds.isEmpty {
            let options = RadioOptions(style: .similar, limit: 22, allowExplicit: allowExplicit)
            await withTaskGroup(of: [SongItem].self) { group in
                for seed in seeds {
                    group.addTask {
                        let radio = try? await PersonalizationService.shared.fetchRadio(
                            videoId: seed.videoId, options: options, includeAutomix: false
                        )
                        return radio?.songs ?? []
                    }
                }
                for await songs in group { lanes.append(songs) }
            }
        }
        guard stillCurrent() else { return .cancelled }
        let queue = YourWaveMix.build(likes: eligible, recommendations: lanes, limit: 35)
        guard !queue.isEmpty else { return .noLikes }
        PlaybackQueue.play(queue, log: Log.nowPlaying, context: "yourWave")
        return .started
    }

    /// Video id → position in the all-time most played list. Songs with no plays
    /// are absent and sort after every played one.
    private static func playRank() async -> [String: Int] {
        let top = (try? await DatabaseService.shared.fetchTopSongs(limit: 400))?.toSongItems() ?? []
        var rank: [String: Int] = [:]
        for (index, song) in top.enumerated() where rank[song.videoId] == nil {
            rank[song.videoId] = index
        }
        return rank
    }

    /// Seeds are the most played likes, one per artist, so the radio follows
    /// taste rather than a random shuffle of the library.
    private static func seeds(from songs: [SongItem]) -> [SongItem] {
        var artists = Set<String>()
        var chosen: [SongItem] = []
        let youtube = songs.filter { $0.videoId.utf8.count == 11 && !$0.videoId.contains(":") }
        for song in youtube where chosen.count < 4 {
            let artist = YourWaveMix.artistKey(song)
            if artists.insert(artist).inserted { chosen.append(song) }
        }
        return chosen
    }
}

// Keep ranking independent of network and playback so the mix can be tested.
enum YourWaveMix {
    /// Favourites first in the order they were handed over (most played first),
    /// then recommendations: familiar artists before discoveries, with the rest
    /// of the likes filling the gaps. Never three tracks of one artist in a row.
    static func build(likes: [SongItem], recommendations: [[SongItem]], limit: Int) -> [SongItem] {
        guard limit > 0 else { return [] }
        let familiar = Set(likes.map(artistKey))
        let likedIDs = Set(likes.map(\.videoId))
        var seen = Set<String>()
        var seenRecordings = Set<String>()
        var known: [SongItem] = []
        var discoveries: [SongItem] = []
        let depth = recommendations.map(\.count).max() ?? 0
        for index in 0..<depth {
            for lane in recommendations where lane.indices.contains(index) {
                let song = lane[index]
                let title = normalized(song.title)
                let variants = ["karaoke", "nightcore", "slowed", "sped up", "tribute", "8d audio", "instrumental cover"]
                let recording = "\(artistKey(song))\u{1f}\(title)"
                guard song.isAvailable, !title.isEmpty, !likedIDs.contains(song.videoId),
                      !variants.contains(where: { " \(title) ".contains(" \($0) ") }),
                      seen.insert(song.videoId).inserted, seenRecordings.insert(recording).inserted else { continue }
                if familiar.contains(artistKey(song)) { known.append(song) }
                else { discoveries.append(song) }
            }
        }

        var pool: [SongItem] = []
        pool.append(contentsOf: likes)
        for index in 0..<max(known.count, discoveries.count) {
            if known.indices.contains(index) { pool.append(known[index]) }
            if discoveries.indices.contains(index) { pool.append(discoveries[index]) }
        }

        var result: [SongItem] = []
        var used = Set<String>()
        while result.count < limit {
            let last = result.last.map(artistKey)
            let beforeLast = result.dropLast().last.map(artistKey)
            let repeating = last != nil && last == beforeLast ? last : nil
            guard let index = pool.firstIndex(where: {
                !used.contains($0.videoId) && artistKey($0) != repeating
            }) else { break }
            let song = pool.remove(at: index)
            used.insert(song.videoId)
            result.append(song)
        }
        return result
    }

    static func artistKey(_ song: SongItem) -> String {
        guard let artist = song.artists.first else { return song.videoId }
        let name = normalized(artist.name)
        return name.isEmpty ? song.videoId : name
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

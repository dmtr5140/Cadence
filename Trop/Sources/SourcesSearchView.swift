//
// SourcesSearchView.swift
// Trop
//
// One search field over every enabled service, with the mode switch on top:
// all services mixed, or a single one.
//

import SwiftUI

struct SourcesSearchView: View {
    @Environment(SourceRegistry.self) private var registry
    @State private var query = ""
    @State private var tracks: [SourceTrack] = []
    @State private var failures: [SourceID: String] = [:]
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        @Bindable var registry = registry

        List {
            Section {
                Picker("Режим", selection: $registry.mode) {
                    ForEach(SourceRegistry.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if registry.mode == .only {
                    Picker("Сервис", selection: $registry.only) {
                        ForEach(SourceID.allCases.filter { $0.isAvailable && $0 != .youtube }) { id in
                            Text(id.title).tag(id)
                        }
                    }
                }
            }

            if isSearching && tracks.isEmpty {
                Section { ProgressView() }
            }

            ForEach(tracks) { track in
                Button {
                    play(track)
                } label: {
                    SourceTrackRow(track: track)
                }
                .buttonStyle(.plain)
            }

            if !failures.isEmpty {
                Section("Не ответили") {
                    ForEach(Array(failures.keys), id: \.rawValue) { id in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id.title).font(.subheadline.weight(.semibold))
                            Text(failures[id] ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if tracks.isEmpty && !isSearching && !query.isEmpty {
                Section {
                    Text("Ничего не нашлось").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Источники")
        .searchable(text: $query, prompt: "Трек, артист, альбом")
        .autocorrectionDisabled()
        .onChange(of: query) { _, value in
            schedule(value)
        }
        .onChange(of: registry.mode) { _, _ in schedule(query) }
        .onChange(of: registry.only) { _, _ in schedule(query) }
        .onDisappear { searchTask?.cancel() }
    }

    private func schedule(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            tracks = []
            failures = [:]
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let result = await registry.searchAll(trimmed, limit: 25)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                tracks = result.tracks
                failures = result.failures
                isSearching = false
            }
        }
    }

    private func play(_ track: SourceTrack) {
        Task {
            await registry.prepareNativePlayback(for: [track])
            let index = tracks.firstIndex(of: track) ?? 0
            let songs = tracks.map(SongItem.init(source:))
            await MainActor.run {
                NowPlaying.shared.setQueue(songs, startIndex: index)
            }
        }
    }
}

private struct SourceTrackRow: View {
    let track: SourceTrack

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: track.artwork.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(track.source.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if track.duration > 0 {
                Text(Self.time(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    static func time(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension SongItem {
    /// A row from any service in the shape the queue and the player expect.
    init(source track: SourceTrack) {
        self.init(
            videoId: track.playbackKey,
            title: track.title,
            artists: [YTArtist(name: track.artist, id: nil)],
            album: track.album,
            albumId: nil,
            duration: track.duration,
            thumbnailUrl: track.artwork,
            isExplicit: track.isExplicit,
            playlistId: nil,
            likeStatus: nil,
            viewCount: nil,
            year: nil,
            isVideo: false,
            musicVideoType: nil,
            addedBy: nil,
            isUnavailable: nil
        )
    }
}

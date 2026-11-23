//
//  YouTubeCanvasPicker.swift
//  Trop
//
//  Search a music video, drag to the moment, loop it. The choice is stored as
//  the video id plus a window, so it outlives the expiring stream link and
//  works for tracks that have no Canvas anywhere else.
//

import AVFoundation
import AVKit
import SwiftUI

struct YouTubeCanvasPicker: View {
    let trackId: String
    var suggestedQuery: String = ""
    var onPicked: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var clips: [CanvasYouTube.Clip] = []
    @State private var isSearching = false
    @State private var selected: CanvasYouTube.Clip?
    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var start: Double = 0
    @State private var length: Double = 6
    @State private var isResolving = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                TextField("Song or artist", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }

                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Text("Search YouTube")
                        Spacer()
                        if isSearching { ProgressView() }
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearching)
            } header: {
                Text("Search")
            } footer: {
                Text("Music videos only. The clip plays muted and loops in the player.")
            }

            if let selected {
                previewSection(for: selected)
            }

            if !clips.isEmpty {
                Section("Results") {
                    ForEach(clips) { clip in
                        Button { choose(clip) } label: { row(clip) }
                            .buttonStyle(.plain)
                    }
                }
            }

            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Clip from YouTube")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task {
            guard clips.isEmpty else { return }
            query = suggestedQuery
            if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                await search()
            }
        }
        .onDisappear { detach() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func previewSection(for clip: CanvasYouTube.Clip) -> some View {
        Section {
            ZStack {
                Color.black
                if let player {
                    CanvasVideoSurface(player: player)
                } else if isResolving {
                    ProgressView().tint(.white)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .listRowInsets(EdgeInsets())

            VStack(alignment: .leading, spacing: 6) {
                Text("Start at \(timecode(start))").font(.subheadline)
                Slider(
                    value: $start,
                    in: 0...max(1, (clip.seconds ?? 180) - length),
                    step: 0.5,
                    onEditingChanged: { editing in
                        if !editing { restart() }
                    }
                )
            }

            Picker("Loop length", selection: $length) {
                Text("4 s").tag(4.0)
                Text("6 s").tag(6.0)
                Text("8 s").tag(8.0)
                Text("12 s").tag(12.0)
            }
            .pickerStyle(.segmented)
            .onChange(of: length) { _, _ in restart() }

            Button {
                apply(clip)
            } label: {
                Label("Use This Moment", systemImage: "checkmark.circle")
            }
        } header: {
            Text(clip.title)
        } footer: {
            Text("Tap a result to preview it, then drag to the moment you want.")
        }
    }

    private func row(_ clip: CanvasYouTube.Clip) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: clip.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title).font(.body).lineLimit(2)
                HStack(spacing: 6) {
                    if !clip.channel.isEmpty {
                        Text(clip.channel).lineLimit(1)
                    }
                    if !clip.duration.isEmpty {
                        Text(clip.duration).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if selected?.id == clip.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    // MARK: - Actions

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        let found = await CanvasYouTube.search(query)
        clips = found
        errorText = found.isEmpty ? "Nothing found. Try the artist name." : nil
    }

    private func choose(_ clip: CanvasYouTube.Clip) {
        detach()
        selected = clip
        start = 0
        Task { await attach(clip) }
    }

    private func attach(_ clip: CanvasYouTube.Clip) async {
        isResolving = true
        defer { isResolving = false }
        guard let url = await CanvasYouTube.streamURL(for: clip.id) else {
            errorText = "This video cannot be played here. Try another result."
            return
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        restart()
    }

    /// Seeks to the chosen moment and jumps back once the window ends, so the
    /// preview shows exactly what the player will loop.
    private func restart() {
        guard let player else { return }
        removeObserver()
        let begin = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let finish = start + max(2, length)
        player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { time in
            if time.seconds >= finish || time.seconds < start - 0.5 {
                player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.play()
    }

    private func apply(_ clip: CanvasYouTube.Clip) {
        CanvasStore.setYouTube(
            CanvasStore.YouTubePick(
                clipId: clip.id,
                start: max(0, start),
                length: max(2, length)
            ),
            for: trackId
        )
        CanvasService.shared.forget(videoId: trackId)
        onPicked()
        dismiss()
    }

    private func removeObserver() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func detach() {
        removeObserver()
        player?.pause()
        player = nil
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Surface

/// Bare AVPlayerLayer, aspect-filled, no controls.
private struct CanvasVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}

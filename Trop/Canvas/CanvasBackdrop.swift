//
//  CanvasBackdrop.swift
//  Trop
//
//  The looping video layer that sits under the player. Muted, gapless, and
//  invisible when the track has no clip — no black rectangle, no placeholder.
//

import AVFoundation
import AVKit
import SwiftUI

struct CanvasBackdrop: View {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    /// How dark the scrim over the video is; the lyrics need contrast.
    var dim: Double = 0.4

    @State private var player: AVPlayer?
    @State private var looper: AVPlayerLooper?
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            if let player {
                CanvasPlayerLayer(player: player)
                Color.black.opacity(dim)
            }
        }
        .allowsHitTesting(false)
        .task(id: videoId) { await load() }
        .onDisappear { stop() }
    }

    private func load() async {
        stop()
        guard !videoId.isEmpty else { return }

        // A moment picked by hand wins over both automatic sources. Its link
        // expires between launches, so it is resolved here every time.
        if let pick = CanvasStore.youTubePick(for: videoId) {
            guard let url = await CanvasYouTube.streamURL(for: pick.clipId) else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(url: url))
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            self.player = player
            playWindow(pick, on: player)
            return
        }

        guard let url = await CanvasService.shared.canvas(videoId: videoId,
                                                          title: title,
                                                          artist: artist,
                                                          album: album) else { return }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        queue.preventsDisplaySleepDuringVideoPlayback = false
        // The looper keeps the clip seamless; HLS clips from the catalogue are
        // short VODs, so it loops the same way a local file would.
        let loop = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()

        player = queue
        looper = loop
    }

    private func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        looper = nil
    }

    /// Plays the chosen window: seek to its start, then jump back when it ends.
    private func playWindow(_ pick: CanvasStore.YouTubePick, on player: AVPlayer) {
        let begin = CMTime(seconds: max(0, pick.start), preferredTimescale: 600)
        let finish = pick.start + max(2, pick.length)
        player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { time in
            if time.seconds >= finish {
                player.seek(to: begin, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        player.play()
    }
}

// MARK: - Layer

private struct CanvasPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
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
            // `layerClass` makes the backing layer an AVPlayerLayer.
            layer as! AVPlayerLayer
        }
    }
}

//
//  CanvasStage.swift
//  Trop
//
//  The Canvas alone: the clip fills the screen, the cover and every control
//  are gone, and only the song's name, its artist and one button sit at the
//  bottom. A tap anywhere on the video returns to the player.
//

import SwiftUI

struct CanvasStage<Accessory: View>: View {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let onClose: () -> Void
    /// Apple Music shows the clip for a heartbeat and then lets go. Nil keeps
    /// the stage until the user taps.
    var autoHideAfter: TimeInterval? = 5
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .ignoresSafeArea()

            CanvasBackdrop(
                videoId: videoId,
                title: title,
                artist: artist,
                album: album,
                dim: 0
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                accessory()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 34)
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        // The timer dies with the view, so a tap and the timer never both
        // fire. A nil interval keeps the stage up until the tap.
        .task {
            guard let autoHideAfter else { return }
            try? await Task.sleep(for: .seconds(autoHideAfter))
            guard !Task.isCancelled else { return }
            onClose()
        }
        .accessibilityAction(.escape) { onClose() }
        // The stage is the whole screen: the clock, the battery and the home
        // bar would sit on top of the clip.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

extension Notification.Name {
    /// Asks the player to open the Canvas stage. Object is the video id, so a
    /// menu opened for another row cannot open a stage it does not own.
    static let canvasStageRequested = Notification.Name("canvas.stage.requested")
}

/// The player's way into the stage: it looks the clip up once per track and
/// stays out of the row when there is nothing to show.
struct CanvasStageButton: View {
    let videoId: String?
    let title: String
    let artist: String
    let album: String?
    let onOpen: () -> Void

    @State private var isAvailable = false

    // A ZStack, not a Group: `.task` attached to an empty Group never runs,
    // so the probe would sit at `false` forever and the button never appear.
    var body: some View {
        ZStack {
            if isAvailable {
                Button(action: onOpen) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Canvas")
                .transition(.opacity)
            }
        }
        .frame(width: isAvailable ? 32 : 0, height: 32)
        .task(id: videoId) { await probe() }
    }

    @MainActor
    private func probe() async {
        guard let videoId, !videoId.isEmpty else {
            isAvailable = false
            return
        }
        // A clip picked by hand or imported from Photos is already on disk;
        // no lookup can beat it, and the network may know nothing about it.
        if CanvasStore.url(for: videoId) != nil {
            isAvailable = true
            return
        }
        let url = await CanvasService.shared.canvas(
            videoId: videoId,
            title: title,
            artist: artist,
            album: album
        )
        isAvailable = url != nil
    }
}

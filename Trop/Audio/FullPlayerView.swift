//
//  FullPlayerView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI

struct FullPlayerView: View {
    let onCollapse: () -> Void
    let artworkTopInset: CGFloat

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared

    @ObservedObject private var likeStore = LikeStore.shared
    private var isLiked: Bool {
        guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }
    private var currentLikeFlavor: LikeFlavor {
        guard np.queueSongs.indices.contains(np.queueIndex) else { return .unknown }
        let song = np.queueSongs[np.queueIndex]
        return LikeFlavor.guess(videoId: song.videoId, title: song.title, artists: song.artists.map(\.name), album: song.album)
    }
    @State private var showLyrics = false
    @AppStorage(LyricsState.karaokeEnabledKey) private var karaokeEnabled = false
    /// Karaoke lyrics drop their glass panel; the artwork and title step aside
    /// so only the lyrics sit over the player background.
    private var showsKaraoke: Bool { showLyrics && karaokeEnabled && LyricsState.shared.hasWordTiming }
    @State private var showQueue = false
    /// The speed dial under the progress bar, opened from its chip.
    @State private var showsSpeedDial = false
    /// True while an open dial shrinks back into its chip, before the layout closes its room.
    @State private var isSpeedDialFolding = false
    @State private var isOpeningArtist = false
    @State private var artistUnavailable = false
    /// How far the cover pages are dragged sideways by the track swipe.
    @State private var artworkDragOffset: CGFloat = 0
    @State private var isCommittingSwipe = false
    private static let sleepOverlayBleed: CGFloat = 8
    @State private var titleChangeTrigger = 0
    @State private var titleChangeDirection: CGFloat = 1
    @State private var lastTitleQueueIndex = NowPlaying.shared.queueIndex
    /// Timed, non-empty lines of the current song, for the lyric preview.
    @State private var syncedLyrics: [LyricLine] = []
    /// How far the player is pulled down by the dismiss gesture.
    @State private var pullDistance: CGFloat = 0
    /// The hidden full-screen cover, opened by pinching the cover out.
    @State private var showsFullscreenCover = false
    /// The Canvas alone: no cover, no controls, just the clip.
    @State private var showsCanvasStage = false
    /// Where the current cover sits on screen, for the full-screen cover to
    /// grow from. A plain box, not state: the swipe and pull move the cover
    /// every frame and must not redraw the player.
    @State private var coverFrame = CoverFrameBox()
    /// The controls row and the secondary row, for the Radio Bloom. Boxes, like `coverFrame`.
    @State private var controlsFrame = CoverFrameBox()
    @State private var secondaryFrame = CoverFrameBox()
    /// The cover pager's frame, so the skip buttons slide it one page.
    @State private var pagerFrame = CoverFrameBox()
    @State private var karaokeReplacesPlay = false
    @State private var isLandscape = false
    @State private var radioReplacesPlay = false
    private var playerBackgroundColors: [Color] { np.dominantColors }
    private var showsCardCover: Bool { settings.playerStyle == .card }

    /// The landscape Immersive cover: from the screen's leading edge to a little past the middle.
    private func landscapeCoverWidth(_ geometry: GeometryProxy) -> CGFloat {
        geometry.safeAreaInsets.leading + geometry.size.width * 0.54
    }
    /// Dark enough for the white controls, at a 4.5:1 contrast, on a pale cover too.
    private var readableBackgroundColors: [Color] { playerBackgroundColors.map { $0.darkened(toLuminance: 0.18) } }

    var body: some View {
        GeometryReader { geometry in
            playerLifecycle(geometry)
        }
    }

    /// What the player does when the track or a panel changes. Split off from
    /// the body: the whole chain in one expression pushed type checking past
    /// its time budget.
    private func playerLifecycle(_ geometry: GeometryProxy) -> some View {
        playerInteractive(geometry)
            .onChange(of: np.videoId) { oldValue, newValue in
                handleTrackChange(from: oldValue, to: newValue)
            }
            .onChange(of: np.queueSongs.count) { _, _ in
                handleQueueCountChange()
            }
            .onChange(of: np.queueIndex) { _, _ in
                handleQueueIndexChange()
            }
            .onChange(of: showQueue) { _, newValue in
                handleShowQueue(newValue)
            }
            .onChange(of: showLyrics) { _, newValue in
                handleShowLyrics(newValue)
            }
            .task { np.preloadNeighborArtwork() }
            .task(id: np.videoId) { await loadCurrentLyrics() }
            .alert("Artist unavailable", isPresented: $artistUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The artist page could not be found. Try again when connected.")
            }
            .interactiveDismissDisabled(showQueue || showLyrics || showsFullscreenCover)
            .background(
                // Artist and album links from the player open over it, as a sheet.
                Color.clear
                    .routerSheet()
            )
    }

    /// Pull-to-dismiss, the immersive screens and the panels.
    private func playerInteractive(_ geometry: GeometryProxy) -> some View {
        playerVisuals(geometry)
            .offset(y: pullDistance)
            .gesture(pullToDismiss(height: geometry.size.height))
            // Outside the pull offset; it is torn down with the player.
            .overlay { lyricsScreen }
            .overlay { canvasStage }
            .onReceive(NotificationCenter.default.publisher(for: .canvasStageRequested)) { note in
                handleCanvasStageRequest(note)
            }
            .overlay { fullscreenCoverLayer }
    }

    /// The layers themselves plus the animations that follow the panel state.
    private func playerVisuals(_ geometry: GeometryProxy) -> some View {
        ZStack {
            playerBackground
            canvasBackdropLayer
            artworkLayer(geometry)
            playerContent(geometry)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .overlay(alignment: .top) { sleepEndedOverlay(geometry) }
        .overlay { radioBloomLayer }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showQueue)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showLyrics)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: showsKaraoke)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.22), value: showsSpeedDial)
    }

    private func handleQueueCountChange() {
        np.preloadNeighborArtwork()
        preloadLyrics()
    }

    private func handleQueueIndexChange() {
        artworkDragOffset = 0
        np.preloadNeighborArtwork()
    }

    private func handleShowQueue(_ value: Bool) {
        if value {
            showLyrics = false
            np.preloadNeighborArtwork()
        }
    }

    private func handleShowLyrics(_ value: Bool) {
        if value { showQueue = false }
    }

    /// The gradient behind everything: solid black, the cover's palette in card
    /// mode, or the readable two-stop gradient with its glow.
    @ViewBuilder
    private var playerBackground: some View {
        ZStack {
        if settings.playerBackgroundStyle == .solid {
            Color.black
                .ignoresSafeArea()
        } else if settings.playerStyle == .card {
            // The cover's colour, brighter at the top and dark enough for
            // white text from the middle down, where the controls sit.
            let base = playerBackgroundColors.first ?? .black
            LinearGradient(
                stops: [
                    .init(color: base.mix(with: .black, by: 0.15), location: 0),
                    .init(color: base.mix(with: .black, by: 0.6), location: 0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .id(playerBackgroundColors)
            .transition(.opacity)
        } else {
            LinearGradient(
                colors: [
                    readableBackgroundColors.first ?? Color(red: 0.15, green: 0.15, blue: 0.2),
                    readableBackgroundColors.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // An overlay, not a ZStack sibling: on a screen narrower than
            // 400 points the glow's fixed width would widen the player,
            // shift it right and show the previous cover at the left edge.
            .overlay {
                Circle()
                    .fill(readableBackgroundColors.first ?? .blue)
                    .frame(width: 400, height: 400)
                    .blur(radius: 120)
                    .opacity(0.45)
                    .offset(y: -150)
            }
            .ignoresSafeArea()
            .id(playerBackgroundColors)
            .transition(.opacity)
        }
        }
        .animation(.easeInOut(duration: 0.8), value: playerBackgroundColors)
    }

    /// The canvas clip, dimmed, behind the cover and the lyrics.
    @ViewBuilder
    private var canvasBackdropLayer: some View {
        // Canvas: the album's looping clip behind the cover and the
        // lyrics, dimmed so white text keeps its contrast. A track
        // without a clip leaves the gradient untouched.
        if settings.showCanvas,
           settings.playerBackgroundStyle != .solid,
           let videoId = np.videoId {
            CanvasBackdrop(
                videoId: videoId,
                title: np.title,
                artist: np.displayArtist,
                album: np.albumTitle.isEmpty ? nil : np.albumTitle,
                dim: 0.55
            )
            .ignoresSafeArea()
        }

    }

    /// The cover pager: a full column in landscape, a short block in portrait.
    @ViewBuilder
    private func artworkLayer(_ geometry: GeometryProxy) -> some View {
        if !showsCardCover, isLandscape {
            // The cover fills the left column up to the screen's edges and
            // fades out sideways, under the start of the controls.
            let insets = geometry.safeAreaInsets
            let pageSize = CGSize(
                width: landscapeCoverWidth(geometry),
                height: geometry.size.height + artworkTopInset + insets.bottom
            )
            artworkPager(pageSize: pageSize)
                .frame(width: pageSize.width, height: pageSize.height)
                .compositingGroup()
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.6),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .offset(x: -insets.leading, y: -artworkTopInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(showsKaraoke ? 0 : 1)
        } else if !showsCardCover {
            // Shorter while the speed dial is open, so the title stays on the faded part.
            let artworkHeight = (geometry.size.height + artworkTopInset) * (showsSpeedDial ? 0.48 : 0.58)
            // Clipped to the screen width, so a neighbour shows only the
            // part dragged in from the edge.
            artworkPager(pageSize: CGSize(width: geometry.size.width, height: artworkHeight))
                .frame(maxWidth: .infinity)
                .frame(height: artworkHeight)
                .compositingGroup()
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.86),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .offset(y: -artworkTopInset)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(showsKaraoke ? 0 : 1)
        }

    }

    /// Handle, artwork, title and controls, laid out for the current orientation.
    @ViewBuilder
    private func playerContent(_ geometry: GeometryProxy) -> some View {
        if isLandscape {
            // Two columns, so nothing has to shrink below a usable size:
            // the cover (and an open panel) on the left, the controls on the right.
            HStack(spacing: 24) {
                artworkArea(pageWidth: showsCardCover ? geometry.size.width / 2 : landscapeCoverWidth(geometry))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { playerPanel }

                VStack(spacing: 0) {
                    playerHandle

                    titleAndActionsRow
                        .padding(.bottom, 12)
                        .opacity(showsKaraoke ? 0 : 1)

                    Spacer(minLength: 0)

                    controlsSection
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
        } else {
            VStack(spacing: 0) {
                playerHandle

                VStack(spacing: 0) {
                    artworkArea(pageWidth: geometry.size.width)

                    titleAndActionsRow
                        .padding(.horizontal, 32)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        .opacity(showsKaraoke ? 0 : 1)

                    // Hidden under an open panel: the glass is see-through.
                    PlayerLyricPreview(lines: syncedLyrics) { showLyrics = true }
                        .opacity(showQueue || showLyrics ? 0 : 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // No bottom padding: the panel covers the lyric line and the
                // progress bar's touch area leaves the gap above its track.
                .overlay {
                    playerPanel
                        .padding(.horizontal, 20)
                }

                controlsSection
            }
        }
    }

    /// Sized and offset like the artwork, so the animation lands on the player
    /// rather than sliding with the safe area.
    private func sleepEndedOverlay(_ geometry: GeometryProxy) -> some View {
        let size = CGSize(
            width: geometry.size.width + 2 * Self.sleepOverlayBleed,
            height: geometry.size.height + artworkTopInset
        )
        return SleepEndedOverlay(size: size)
            .frame(width: size.width, height: size.height)
            .offset(y: -artworkTopInset)
    }

    /// The lifted-cover transition, kept out of the body for the type checker.
    @ViewBuilder
    private var fullscreenCoverLayer: some View {
        if showsFullscreenCover {
            FullscreenCoverOverlay(
                source: coverFrame.rect,
                sourceCornerRadius: showsCardCover ? Self.cardCoverRadius : 0,
                fadesBottom: !showsCardCover,
                onClosed: { showsFullscreenCover = false },
                cover: { cover(for: $0) }
            )
        }
    }
    private func closePanelOrPlayer() {
        if showQueue {
            showQueue = false
        } else if showLyrics {
            showLyrics = false
        } else {
            onCollapse()
        }
    }

    /// Progress, playback controls, volume and the secondary row.
    @ViewBuilder
    private var controlsSection: some View {
        // No top padding: the bar's touch area already leaves a gap
        // above the track, and the lyric line belongs with it.
        PlayerProgressSection(
            hidesChip: showsSpeedDial && !isSpeedDialFolding,
            onChipTap: {
                isSpeedDialFolding = false
                showsSpeedDial = true
            }
        )
        .padding(.bottom, 16)

        // Takes its room from the cover area above, and grows out of
        // the speed chip: its top centre sits right under the chip.
        if showsSpeedDial {
            PlaybackSpeedDial(onClose: closeSpeedDial)
                .scaleEffect(isSpeedDialFolding ? 0.08 : 1, anchor: .top)
                .opacity(isSpeedDialFolding ? 0 : 1)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.08, anchor: .top).combined(with: .opacity))
                .accessibilityAction(.escape, closeSpeedDial)
        }

        Color.clear.frame(height: 8)

        PlaybackControlsRow(
            isPlaying: np.isPlaying,
            hasPrevious: np.hasPrevious,
            hasNext: np.hasNext,
            onPrevious: { skip(.previous) },
            onPlayPause: { player.togglePlayPause() },
            onNext: { skip(.next) },
            hidesPlayPause: karaokeReplacesPlay || radioReplacesPlay
        )
        // The karaoke mascot takes the play button's place.
        .overlay {
            KaraokeCountdownOverlay(
                trigger: LyricsState.shared.karaokeGreeting,
                isOn: LyricsState.shared.karaokeGreetingIsOn,
                replacesPlayButton: $karaokeReplacesPlay
            )
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlsFrame.rect = $0 }
        .padding(.bottom, 8)

        PlayerVolumeSlider()

        Color.clear.frame(height: 4)

        SecondaryActionsRow(
            showQueue: $showQueue,
            isRepeatOn: $np.isRepeatOn,
            showLyrics: $showLyrics
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { secondaryFrame.rect = $0 }

        Color.clear.frame(height: 8)
    }

    private var playerHandle: some View {
        Button(action: closePanelOrPlayer) {
            Capsule()
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showQueue ? "Close queue" : showLyrics ? "Close lyrics" : "Collapse player")
    }

    @ViewBuilder
    private var playerPanel: some View {
        if showQueue {
            QueueView(
                showQueue: $showQueue,
                isShuffleOn: $np.isShuffleOn,
                isRepeatOn: $np.isRepeatOn
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            .environment(\.colorScheme, .dark)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            .accessibilityAction(.escape) { closePanelOrPlayer() }
        }
    }

    /// Lyrics take the whole player, the way Apple Music shows them: no card,
    /// no border, the record's colours behind the words and nothing else on
    /// screen — the artwork, the title and the controls all step aside.
    @ViewBuilder
    private var lyricsScreen: some View {
        if showLyrics {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .background(Color.black.opacity(0.35))
                    .ignoresSafeArea()
                LyricsView(showLyrics: $showLyrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea(edges: .bottom)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            .accessibilityAction(.escape) { closePanelOrPlayer() }
        }
    }

    /// The Canvas on its own. Everything else — the cover, the title row, the
    /// controls — steps aside, and a tap on the clip brings the player back.
    @ViewBuilder
    /// Kept out of the player's modifier chain: inlined it made the whole body
    /// too complex for the type checker.
    private var radioBloomLayer: some View {
        RadioBloomOverlay(
            event: np.radioBloom,
            cover: { coverFrame.rect },
            // The row is symmetric: the play button sits at its centre.
            playButton: { controlsFrame.rect },
            // The queue button is the last of the row's three equal columns.
            queueButton: { queueButtonRect },
            coverCornerRadius: showsCardCover ? Self.cardCoverRadius : 0,
            isImmersive: !showsCardCover,
            replacesPlayButton: $radioReplacesPlay
        )
    }

    private var queueButtonRect: CGRect {
        let row = secondaryFrame.rect
        return CGRect(x: row.maxX - row.width / 3, y: row.minY, width: row.width / 3, height: row.height)
    }

    /// Only the track on screen may answer: the menu also exists on rows of the
    /// queue and of every list.
    private func handleCanvasStageRequest(_ note: Notification) {
        guard let id = note.object as? String, id == np.videoId else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            showsCanvasStage = true
        }
    }

    /// Everything the player does when the track changes. Kept out of the
    /// view builder: the five statements inlined there pushed type inference
    /// past its time budget.
    private func handleTrackChange(from oldValue: String?, to newValue: String?) {
        if oldValue != nil, newValue != nil {
            titleChangeDirection = np.queueIndex < lastTitleQueueIndex ? -1 : 1
            titleChangeTrigger &+= 1
        }
        lastTitleQueueIndex = np.queueIndex
        showLyrics = false
        preloadLyrics()
    }

    @ViewBuilder
    private var canvasStage: some View {
        if showsCanvasStage {
            CanvasStage(
                videoId: np.videoId ?? "",
                title: np.title,
                artist: np.displayArtist,
                album: np.albumTitle.isEmpty ? nil : np.albumTitle,
                onClose: { showsCanvasStage = false }
            ) {
                PlayerLikeButton(isLiked: isLiked, flavor: currentLikeFlavor) {
                    guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                    Task { await likeStore.toggle(song: song) }
                }
            }
            .transition(.opacity)
            .zIndex(20)
            .onChange(of: np.videoId) { _, _ in showsCanvasStage = false }
        }
    }

    // MARK: - Gestures

    private func pullToDismiss(height: CGFloat) -> PlayerDismissGesture {
        PlayerDismissGesture(isEnabled: !showQueue && !showLyrics && !showsFullscreenCover) { distance in
            pullDistance = max(0, distance)
        } onEnded: { distance, velocity in
            // Far enough (a fifth of the screen) or a quick flick closes it.
            if distance > height * 0.2 || (distance > 20 && velocity > 800) {
                onCollapse()
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { pullDistance = 0 }
            }
        }
    }

    /// The skip buttons slide the covers like a swipe. A tap during a slide,
    /// or with the cover off screen, changes song at once.
    private func skip(_ direction: TrackSwipe.Direction) {
        let width = pagerFrame.rect.width
        guard width > 0, !isCommittingSwipe, !showQueue, !showLyrics else {
            direction == .next ? np.playNext() : np.playPrevious()
            return
        }
        TrackSwipe.commit(direction, pageWidth: width, offset: $artworkDragOffset, isCommitting: $isCommittingSwipe)
    }

    /// The cover follows the finger, like the mini player's pages, and the
    /// neighbour's cover slides in from the edge.
    private func playerSwipe(pageWidth: CGFloat) -> PlayerTrackSwipeGesture {
        PlayerTrackSwipeGesture(
            isEnabled: !showQueue && !showLyrics && settings.artworkSwipeNavigation
        ) { translation in
            guard !isCommittingSwipe else { return }
            // No song on that side: the cover stretches a little and springs back.
            let hasNeighbour = translation < 0 ? np.hasNext : np.hasPrevious
            artworkDragOffset = hasNeighbour ? translation : translation / 4
        } onEnded: { predictedEnd in
            guard !isCommittingSwipe else { return }
            // Held past the threshold, or flicked hard enough to coast past it.
            if predictedEnd <= -pageWidth * TrackSwipe.commitFraction, np.hasNext {
                TrackSwipe.commit(.next, pageWidth: pageWidth, offset: $artworkDragOffset, isCommitting: $isCommittingSwipe)
            } else if predictedEnd >= pageWidth * TrackSwipe.commitFraction, np.hasPrevious {
                TrackSwipe.commit(.previous, pageWidth: pageWidth, offset: $artworkDragOffset, isCommitting: $isCommittingSwipe)
            } else {
                withAnimation(TrackSwipe.springBack) { artworkDragOffset = 0 }
            }
        }
    }

    /// Two fingers spreading on the cover open it full screen. Simultaneous,
    /// so the one-finger track swipe and pull-down are untouched.
    private var fullscreenCoverPinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard value.magnification > 1.25, !showsFullscreenCover, !showQueue, !showLyrics else { return }
                showsFullscreenCover = true
            }
    }

    // MARK: - Player Content

    private func preloadLyrics() {
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private func loadCurrentLyrics() async {
        guard let videoId = np.videoId else {
            syncedLyrics = []
            return
        }
        syncedLyrics = []
        guard let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId),
              !Task.isCancelled,
              np.videoId == videoId else { return }
        syncedLyrics = lines.filter {
            $0.startTime != nil &&
                !$0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪*· ")).isEmpty
        }
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .center) {
            PlayerTitleBlock(
                title: np.title,
                artist: np.displayArtist,
                spacing: 2,
                titleFont: .title3.weight(.semibold),
                onArtistTap: { openCurrentArtist() }
            )
            .disabled(isOpeningArtist)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: titleChangeTrigger) { content, offset in
                content.offset(x: reduceMotion ? 0 : offset * titleChangeDirection)
            } keyframes: { _ in
                MoveKeyframe(CGFloat(18))
                SpringKeyframe(CGFloat.zero, duration: 0.45, spring: .bouncy)
            }

            Spacer()

            // Like and menu sit in tinted circles, close to the title block.
            // The Canvas entry and the download badge live in the song menu:
            // in Apple Music nothing else is in this row.
            HStack(spacing: 10) {
                PlayerLikeButton(isLiked: isLiked, flavor: currentLikeFlavor) {
                    guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                    Task { await likeStore.toggle(song: song) }
                }
                .frame(width: 36, height: 36)
                .background(.white.opacity(isLiked ? 0 : 0.14), in: Circle())

                if np.queueSongs.indices.contains(np.queueIndex) {
                    PlayerSongMenu(song: np.queueSongs[np.queueIndex], onCollapse: { onCollapse() })
                        .equatable()
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.14), in: Circle())
                }
            }
        }
    }

    private func openCurrentArtist() {
        guard !isOpeningArtist else { return }
        let artist = np.artists.first(where: { !$0.name.isEmpty }) ?? YTArtist(name: np.artist, id: nil)
        guard !artist.name.isEmpty else {
            artistUnavailable = true
            return
        }
        isOpeningArtist = true
        Task { @MainActor in
            defer { isOpeningArtist = false }
            var browseId = artist.id
            if browseId == nil {
                if let json = try? await SearchService.shared.search(query: artist.name) {
                    browseId = SearchParser.parseSearchResults(from: json)
                        .flatMap(\.items)
                        .compactMap { item -> ArtistItem? in
                            if case .artist(let result) = item { return result }
                            return nil
                        }
                        .first(where: { $0.name.caseInsensitiveCompare(artist.name) == .orderedSame })?
                        .browseId
                }
            }
            guard let browseId else {
                artistUnavailable = true
                return
            }
            AppRouter.shared.presentSheet(.artist(browseId: browseId))
        }
    }

    /// The space above the title, where the track swipe starts. The Card
    /// style's cover sits here; the Immersive cover is behind it.
    private func artworkArea(pageWidth: CGFloat) -> some View {
        Group {
            if showsCardCover {
                GeometryReader { area in
                    artworkPager(pageSize: area.size)
                }
                // The neighbours wait a page away; in landscape that is over the controls.
                .clipped()
                .padding(.vertical, 12)
                .opacity(showsKaraoke ? 0 : 1)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(playerSwipe(pageWidth: pageWidth))
        .simultaneousGesture(fullscreenCoverPinch)
        // A tap on the background closes the speed dial.
        .simultaneousGesture(TapGesture().onEnded {
            closeSpeedDial()
        })
    }

    /// Folds the dial into its chip first, with the layout still, then gives
    /// its room back: removed at once, it shrank where it was while the chip slid away.
    private func closeSpeedDial() {
        guard showsSpeedDial, !isSpeedDialFolding else { return }
        withAnimation(.easeIn(duration: reduceMotion ? 0.1 : 0.18)) { isSpeedDialFolding = true }
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.1 : 0.18))
            // The player's animation for `showsSpeedDial` moves the layout; the folded dial is already invisible.
            // Folding stays on, so the removed dial never springs back; opening resets it.
            showsSpeedDial = false
        }
    }

    /// The current cover with the previous and next ones a page to each side,
    /// moved together by the track swipe.
    private func artworkPager(pageSize: CGSize) -> some View {
        ZStack {
            if let previous = np.previousSong {
                artworkPage(for: previous, size: pageSize)
                    .offset(x: -pageSize.width)
            }
            if let current = np.currentSong {
                artworkPage(for: current, size: pageSize)
                    // The full-screen copy lifts off from here; Reduce Motion fades it in over this one.
                    .opacity(showsFullscreenCover && !reduceMotion ? 0 : 1)
                    // AutoMix and crossfades dissolve the old cover into the new one.
                    .id(current.videoId)
                    .transition(.opacity)
            }
            if let next = np.nextSong {
                artworkPage(for: next, size: pageSize)
                    .offset(x: pageSize.width)
            }
        }
        .animation(np.coverDissolves ? .easeInOut(duration: 0.8) : nil, value: np.currentSong?.videoId)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { page in
            pagerFrame.rect = page
            if showsCardCover {
                let side = Self.cardCoverSide(in: page.size)
                coverFrame.rect = CGRect(x: page.midX - side / 2, y: page.midY - side / 2, width: side, height: side)
            } else {
                coverFrame.rect = page
            }
        }
        .offset(x: artworkDragOffset)
    }

    private static let cardCoverRadius: CGFloat = 16

    /// The Card cover is a square inset from the page's sides.
    private static func cardCoverSide(in size: CGSize) -> CGFloat {
        max(0, min(size.width - 64, size.height))
    }

    @ViewBuilder
    private func artworkPage(for song: SongItem, size: CGSize) -> some View {
        if showsCardCover {
            let side = Self.cardCoverSide(in: size)
            cover(for: song)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Self.cardCoverRadius, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .frame(width: size.width, height: size.height)
        } else {
            // Apple's square sleeve: rounded, lifted by a shadow, with a blurred
            // copy of itself glowing behind, and a slight shrink while paused.
            let side = max(0, min(size.width - 48, size.height))
            ZStack {
                cover(for: song)
                    .frame(width: side, height: side)
                    .scaleEffect(0.96)
                    .blur(radius: 20)
                    .saturation(1.8)
                    .opacity(0.4)
                    .offset(y: 8)
                cover(for: song)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(np.isPlaying ? 1 : 0.92)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.72), value: np.isPlaying)
        }
    }

    /// The player's own artwork once it belongs to this song; until then,
    /// and for the neighbours, the cached cover the mini player shows.
    @ViewBuilder
    private func cover(for song: SongItem) -> some View {
        if song.videoId == np.thumbnailVideoId, let uiImage = np.thumbnailUIImage {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            MiniArtworkView(song: song, placeholderIconSize: 64)
                .id(song.videoId)
        }
    }
}

private final class CoverFrameBox {
    var rect: CGRect = .zero
}

/// The current lyric line under the title. Its own view so only this line,
/// not the whole player, redraws as `currentTime` ticks.
private struct PlayerLyricPreview: View {
    let lines: [LyricLine]
    let onTap: () -> Void

    @Environment(SettingsStore.self) private var settings
    private let np = NowPlaying.shared

    private var activeLyricText: String? {
        guard let firstLine = lines.first else { return nil }
        let lyricTime = np.currentTime + LyricsOffset.effective(for: np.videoId)
        return lines.last { line in
            guard let startTime = line.startTime else { return false }
            return startTime <= lyricTime
        }?.text ?? firstLine.text
    }

    var body: some View {
        Group {
            if let activeLyricText {
                Button(action: onTap) {
                    HStack(spacing: 6) {
                        Text(activeLyricText)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.28), value: activeLyricText)
                            .multilineTextAlignment(settings.lyricsAlignment.multilineTextAlignment)
                            .frame(maxWidth: .infinity, alignment: settings.lyricsAlignment.textAlignment)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Current lyric: \(activeLyricText)")
                .accessibilityHint("Opens the lyrics")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 33, alignment: .bottom)
    }
}

/// Progress bar and time labels. Its own view so only this part, not the
/// whole player, redraws as `currentTime` ticks.
private struct PlayerProgressSection: View {
    /// The open dial stands in for the chip.
    let hidesChip: Bool
    let onChipTap: () -> Void

    private let player = PlayerController.shared
    private let np = NowPlaying.shared
    private let speed = PlaybackSpeed.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false

    var body: some View {
        let elapsed = isEditingSlider ? TimeInterval(editingProgress) * np.duration : np.currentTime
        let rate = speed.rate
        VStack(spacing: 6) {
            ProgressBar(
                progress: Binding(
                    get: { isEditingSlider ? editingProgress : np.progress },
                    set: { editingProgress = $0 }
                ),
                accentColor: np.dominantColors.first ?? .white,
                isPlaying: np.isPlaying,
                onEditingChanged: { editing in
                    if !editing {
                        player.seek(to: TimeInterval(editingProgress) * np.duration)
                    }
                    isEditingSlider = editing
                }
            )

            HStack {
                Text(DurationFormat.playbackTime(elapsed))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Away from 1×: the time left at that speed.
                Text(rate == 1
                    ? DurationFormat.playbackTime(np.duration)
                    : "−\(DurationFormat.playbackTime(max(0, np.duration - elapsed) / rate))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            // The dial takes the chip's place while open; its header closes it.
            .overlay {
                speedChip(rate: rate)
                    .scaleEffect(hidesChip ? 0.6 : 1)
                    .opacity(hidesChip ? 0 : 1)
                    .allowsHitTesting(!hidesChip)
            }
        }
        .padding(.horizontal, 32)
    }

    /// Shows the speed and opens the dial; accent-filled away from 1×.
    private func speedChip(rate: Double) -> some View {
        let isChanged = rate != 1
        return Button {
            onChipTap()
        } label: {
            Text(PlaybackSpeed.label(rate))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(isChanged ? SettingsStore.shared.accentColor.opacity(0.55) : .white.opacity(0.14)))
                .overlay { Capsule().strokeBorder(isChanged ? SettingsStore.shared.accentColor : .white.opacity(0.2), lineWidth: 1) }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .tapArea(outset: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed, \(PlaybackSpeed.label(rate))")
        .accessibilityHint("Opens the speed dial")
    }
}

/// The full player's "⋯" menu. `.equatable()` skips the player's redraws
/// here, because a menu rebuilt while open flickers.
private struct PlayerSongMenu: View, Equatable {
    let song: SongItem
    let onCollapse: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.song.videoId == rhs.song.videoId
    }

    var body: some View {
        SongActionsMenu(song: song, showsQueueActions: false, showsSleepTimer: true, onNavigate: { AppRouter.shared.presentSheet($0) }) {
            PlayerOptionsGlyph()
        }
    }
}

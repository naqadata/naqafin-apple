//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import Foundation
import JellyfinAPI
import Logging
import SwiftUI

// TODO: turned into spaghetti to get out, clean up with a better state system
// TODO: verify timer states
// TODO: for tvOS, some kind of focus token system
//       - help with Menu
//       - may help with alternate overlays

@MainActor
class VideoPlayerContainerState: ObservableObject {

    private let logger = Logger.swiftfin()

    @Published
    var isAspectFilled: Bool = false

    @Published
    var isGestureLocked: Bool = false {
        didSet {
            if isGestureLocked {
                isPresentingOverlay = false
            }
        }
    }

    // TODO: rename isPresentingPlaybackButtons
    @Published
    var isPresentingPlaybackControls: Bool = false

    // TODO: replace with graph dependency package
    func setPlaybackControlsVisibility() {

        guard isPresentingOverlay else {
            isPresentingPlaybackControls = false
            return
        }

        if isPresentingOverlay && !isPresentingSupplement {
            isPresentingPlaybackControls = true
            return
        }

        if isCompact {
            if isPresentingSupplement {
                if !isPresentingPlaybackControls {
                    isPresentingPlaybackControls = true
                }
            } else {
                isPresentingPlaybackControls = false
            }
        } else {
            isPresentingPlaybackControls = false
        }
    }

    @Published
    var isCompact: Bool = false {
        didSet {
            setPlaybackControlsVisibility()
        }
    }

    @Published
    var isGuestSupplement: Bool = false

    // TODO: rename isPresentingPlaybackControls
    @Published
    var isPresentingOverlay: Bool = false {
        didSet {
            setPlaybackControlsVisibility()
            presentationControllerShouldDismiss = isPresentingOverlay && !isPresentingSupplement

            if isPresentingOverlay, !isPresentingSupplement {
                timer.poke()
            }
        }
    }

    @Published
    private(set) var isPresentingSupplement: Bool = false {
        didSet {
            setPlaybackControlsVisibility()
            presentationControllerShouldDismiss = isPresentingOverlay && !isPresentingSupplement

            if isPresentingSupplement {
                timer.stop()
            } else {
                isGuestSupplement = false
                timer.poke()
            }
        }
    }

    @Published
    var isScrubbing: Bool = false {
        didSet {
            if isScrubbing {
                timer.stop()
            } else {
                timer.poke()
            }
        }
    }

    @Published
    var presentationControllerShouldDismiss: Bool = false

    @Published
    var selectedSupplement: (any MediaPlayerSupplement)? = nil {
        didSet {
            isPresentingSupplement = selectedSupplement != nil
        }
    }

    @Published
    var isProgressBarFocused: Bool = false

    @Published
    private(set) var activeMediaSegment: MediaSegmentDto?

    @Published
    private(set) var mediaSegmentCountdown: Int?

    var originalPlaybackRate: Float?

    let centerOffsetBox: PublishedBox<CGFloat> = .init(initialValue: 0)
    let jumpProgressObserver: JumpProgressObserver = .init()
    let scrubbedSeconds: PublishedBox<Duration> = .init(initialValue: .zero)
    let timer: PokeIntervalTimer = .init(defaultInterval: UIDevice.isTV ? 10 : 5)
    let toastProxy: ToastProxy = .init()

    weak var containerView: VideoPlayer.UIVideoPlayerContainerViewController?
    weak var manager: MediaPlayerManager?

    #if os(iOS)
    var panHandlingAction: (any _PanHandlingAction)?
    var didSwipe: Bool = false
    var lastTapLocation: CGPoint?
    #endif

    #if os(tvOS)
    @Published
    var isPresentingCloseConfirmation: Bool = false

    @Published
    var isPresentingSubtitleOffset: Bool = false

    @Published
    var isPresentingSubtitleFontSize: Bool = false

    @Published
    var isPresentingPlaybackActionMenu: Bool = false

    var scrubOriginSeconds: Duration?

    func commitScrub() {
        guard isScrubbing else { return }

        manager?.proxy?.setSeconds(scrubbedSeconds.value)
        manager?.setPlaybackRequestStatus(status: .playing)
        isScrubbing = false
        scrubOriginSeconds = nil
    }

    func cancelScrub() {
        guard isScrubbing else { return }

        if let manager {
            scrubbedSeconds.value = manager.seconds
        }

        isScrubbing = false
        scrubOriginSeconds = nil
    }
    #endif

    private var jumpProgressCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var mediaSegmentCountdownTimer: Timer?
    @Published
    private var mediaSegments: [MediaSegmentDto] = []
    private var mediaSegmentItemID: String?
    private var dismissedMediaSegmentIDs: Set<String> = []

    var mediaSegmentsForProgress: [MediaSegmentDto] {
        mediaSegments
    }

    init() {
        timerCancellable = timer.sink { [weak self] in
            guard let self else { return }
            guard !isScrubbing, !isPresentingSupplement, manager?.playbackRequestStatus != .paused else { return }

            withAnimation(.linear(duration: 0.25)) {
                self.isPresentingOverlay = false
            }
        }

        #if os(iOS)
        jumpProgressCancellable = jumpProgressObserver
            .timer
            .sink { [weak self] in
                self?.lastTapLocation = nil
            }
        #endif
    }

    func select(supplement: (any MediaPlayerSupplement)?, isGuest: Bool = false) {
        isGuestSupplement = isGuest

        if supplement?.id == selectedSupplement?.id {
            selectedSupplement = nil
            containerView?.presentSupplementContainer(false)
        } else {
            selectedSupplement = supplement
            containerView?.presentSupplementContainer(supplement != nil)
        }
    }

    // MARK: - Media Segment Skipping

    var shouldShowMediaSegmentSkipButton: Bool {
        activeMediaSegment != nil && mediaSegmentCountdown != nil
    }

    var mediaSegmentSkipTitle: String? {
        guard let type = activeMediaSegment?.type else { return nil }
        return String(format: "Skip %@", type.rawValue)
    }

    func loadMediaSegments(for itemID: String?, at position: Duration) async {
        resetMediaSegments()

        guard let itemID,
              let userSession = Container.shared.currentUserSession()
        else {
            logger.warning("Media segment lookup skipped: missing item or user session")
            return
        }

        mediaSegmentItemID = itemID
        logger.debug("Loading media segments for item \(itemID) at \(position.ticks) ticks")

        do {
            let response = try await userSession.client.send(Paths.getItemSegments(itemID: itemID))
            guard mediaSegmentItemID == itemID else { return }

            mediaSegments = response.value.items ?? []
            let mediaSegmentTypes = mediaSegments.compactMap { $0.type?.rawValue }.joined(separator: ", ")
            logger.info(
                "Loaded \(mediaSegments.count) media segment(s) for item \(itemID): \(mediaSegmentTypes)"
            )
            updateMediaSegment(for: position)
        } catch {
            guard mediaSegmentItemID == itemID else { return }
            mediaSegments = []
            logger.error("Media segment lookup failed for item \(itemID): \(error.localizedDescription)")
        }
    }

    func updateMediaSegment(for position: Duration) {
        let positionTicks = position.ticks
        let segment = mediaSegments.first { segment in
            guard let startTicks = segment.startTicks,
                  let endTicks = segment.endTicks,
                  let type = segment.type
            else { return false }

            return mediaSegmentAction(for: type) != .play
                && positionTicks >= startTicks
                && positionTicks < endTicks - 50_000_000
        }

        guard let segment else {
            if activeMediaSegment != nil {
                logger.debug("Playback left media segment at \(positionTicks) ticks")
            }
            activeMediaSegment = nil
            mediaSegmentCountdown = nil
            mediaSegmentCountdownTimer?.invalidate()
            mediaSegmentCountdownTimer = nil
            dismissedMediaSegmentIDs.removeAll()
            return
        }

        guard mediaSegmentIdentifier(segment) != mediaSegmentIdentifier(activeMediaSegment) else { return }

        activeMediaSegment = segment

        guard let segmentID = mediaSegmentIdentifier(segment), !dismissedMediaSegmentIDs.contains(segmentID) else { return }

        switch mediaSegmentAction(for: segment.type) {
        case .play:
            return
        case .skip:
            skipMediaSegment()
        case .ask:
            let segmentType = segment.type?.rawValue ?? "segment"
            logger.info("Showing Skip \(segmentType) for \(segment.startTicks ?? 0)-\(segment.endTicks ?? 0) at \(positionTicks) ticks")
            mediaSegmentCountdown = 10
            isPresentingOverlay = true
            timer.poke()
            startMediaSegmentCountdown()
        }
    }

    func setMediaSegmentPlaybackActive(_ isActive: Bool) {
        guard shouldShowMediaSegmentSkipButton else { return }

        if isActive {
            startMediaSegmentCountdown()
        } else {
            mediaSegmentCountdownTimer?.invalidate()
            mediaSegmentCountdownTimer = nil
        }
    }

    func skipMediaSegment() {
        guard let endTicks = activeMediaSegment?.endTicks else { return }

        let segmentType = activeMediaSegment?.type?.rawValue ?? "segment"
        logger.info("Skipping \(segmentType) to \(endTicks) ticks")
        let destination = Duration.ticks(endTicks)
        manager?.seconds = destination
        manager?.proxy?.setSeconds(destination)
        dismissActiveMediaSegment()
    }

    private func startMediaSegmentCountdown() {
        mediaSegmentCountdownTimer?.invalidate()

        guard manager?.playbackRequestStatus == .playing else { return }

        mediaSegmentCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.decrementMediaSegmentCountdown()
            }
        }
    }

    private func decrementMediaSegmentCountdown() {
        guard let mediaSegmentCountdown else {
            mediaSegmentCountdownTimer?.invalidate()
            mediaSegmentCountdownTimer = nil
            return
        }

        guard manager?.playbackRequestStatus == .playing else { return }

        if mediaSegmentCountdown <= 1 {
            dismissActiveMediaSegment()
        } else {
            self.mediaSegmentCountdown = mediaSegmentCountdown - 1
        }
    }

    private func dismissActiveMediaSegment() {
        if let segmentID = mediaSegmentIdentifier(activeMediaSegment) {
            dismissedMediaSegmentIDs.insert(segmentID)
        }

        mediaSegmentCountdown = nil
        mediaSegmentCountdownTimer?.invalidate()
        mediaSegmentCountdownTimer = nil
    }

    private func resetMediaSegments() {
        mediaSegments = []
        mediaSegmentItemID = nil
        activeMediaSegment = nil
        mediaSegmentCountdown = nil
        dismissedMediaSegmentIDs.removeAll()
        mediaSegmentCountdownTimer?.invalidate()
        mediaSegmentCountdownTimer = nil
    }

    private func mediaSegmentAction(for type: MediaSegmentType?) -> MediaSegmentAction {
        switch type {
        case .commercial:
            Defaults[.VideoPlayer.MediaSegments.commercialAction]
        case .intro:
            Defaults[.VideoPlayer.MediaSegments.introAction]
        case .outro:
            Defaults[.VideoPlayer.MediaSegments.outroAction]
        case .preview:
            Defaults[.VideoPlayer.MediaSegments.previewAction]
        case .recap:
            Defaults[.VideoPlayer.MediaSegments.recapAction]
        case .unknown, .none:
            .play
        }
    }

    private func mediaSegmentIdentifier(_ segment: MediaSegmentDto?) -> String? {
        guard let segment else { return nil }

        if let id = segment.id {
            return id
        }

        guard let type = segment.type,
              let startTicks = segment.startTicks,
              let endTicks = segment.endTicks
        else { return nil }

        return "\(type.rawValue)-\(startTicks)-\(endTicks)"
    }
}

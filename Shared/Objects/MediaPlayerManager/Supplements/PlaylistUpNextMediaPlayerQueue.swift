//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CollectionHStack
import Combine
import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

/// A queue owned by Playlist Up Next rather than ordinary series autoplay.
/// It resolves the complete Jellyfin playlist once playback starts and keeps
/// its item order for previous/next and natural end-of-item transitions.
@MainActor
final class PlaylistUpNextMediaPlayerQueue: ViewModel, MediaPlayerQueue {

    weak var manager: MediaPlayerManager? {
        didSet {
            loadTask?.cancel()
            cancellables.removeAll()
            guard manager != nil else { return }
            manager?.$playbackItem
                .sink { [weak self] playbackItem in
                    self?.updateAdjacentItems(for: playbackItem?.baseItem.id)
                }
                .store(in: &cancellables)
            isLoadingPlaylist = true
            loadTask = Task { [weak self] in
                await self?.loadPlaylist()
            }.asAnyCancellable()
        }
    }

    let displayTitle: String
    let id: String
    let automaticallyPlaysNext = true

    @Published
    var nextItem: MediaPlayerItemProvider?
    @Published
    var previousItem: MediaPlayerItemProvider?
    @Published
    var hasNextItem = false
    @Published
    var hasPreviousItem = false

    lazy var hasNextItemPublisher: Published<Bool>.Publisher = $hasNextItem
    lazy var hasPreviousItemPublisher: Published<Bool>.Publisher = $hasPreviousItem
    lazy var nextItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $nextItem
    lazy var previousItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $previousItem

    private let context: NaqafinPlaylistUpNextContext
    private let initialItemID: String
    @Published
    private var isLoadingPlaylist = false
    @Published
    private var items: [BaseItemDto] = []
    private var loadTask: AnyCancellable?

    init(context: NaqafinPlaylistUpNextContext, initialItemID: String) {
        self.context = context
        self.initialItemID = initialItemID
        self.displayTitle = context.playlistName
        self.id = "NaqafinPlaylistUpNextMediaPlayerQueue-\(context.playlistID)"
    }

    var videoPlayerBody: some PlatformView {
        InlinePlatformView {
            EmptyView()
        } tvOSView: {
            PlaylistOverlay(queue: self)
        }
    }

    private var upcomingItems: [BaseItemDto] {
        guard !items.isEmpty else { return [] }

        let startIndex: Int = if manager?.item.id == initialItemID, context.isExternalResumeItem {
            context.playlistIndex
        } else if let currentItemID = manager?.item.id,
                  let currentIndex = items.firstIndex(where: { $0.id == currentItemID })
        {
            currentIndex + 1
        } else {
            context.playlistIndex
        }

        guard items.indices.contains(startIndex) else { return [] }
        return Array(items[startIndex...])
    }

    private func loadPlaylist() async {
        defer { isLoadingPlaylist = false }

        guard let userSession = Container.shared.currentUserSession() else { return }

        do {
            var parameters = Paths.GetPlaylistItemsParameters()
            parameters.userID = userSession.user.id
            parameters.fields = .MinimumFields
            parameters.enableUserData = true
            parameters.limit = 1000

            let response = try await userSession.client.send(
                Paths.getPlaylistItems(playlistID: context.playlistID, parameters: parameters)
            )
            guard !Task.isCancelled else { return }

            items = response.value.items ?? []
            updateAdjacentItems(for: manager?.item.id ?? initialItemID)
        } catch is CancellationError {
            // Playback was stopped or a new session was selected.
        } catch {
            logger.debug("Unable to resolve Playlist Up Next queue: \(error.localizedDescription)")
        }
    }

    private func updateAdjacentItems(for currentItemID: String?) {
        guard let currentItemID else { return }

        let currentIndex: Int? = if currentItemID == initialItemID, context.isExternalResumeItem {
            nil
        } else {
            items.firstIndex { $0.id == currentItemID }
        }

        let nextIndex: Int?
        if let currentIndex {
            let next = currentIndex + 1
            nextIndex = items.indices.contains(next) ? next : nil
        } else {
            nextIndex = items.indices.contains(context.playlistIndex) ? context.playlistIndex : nil
        }
        let previousIndex: Int? = currentIndex.flatMap { index in
            let previous = index - 1
            return items.indices.contains(previous) ? previous : nil
        }

        nextItem = nextIndex.flatMap { makeProvider(for: items[$0]) }
        previousItem = previousIndex.flatMap { makeProvider(for: items[$0]) }
        hasNextItem = nextItem != nil
        hasPreviousItem = previousItem != nil
    }

    private func makeProvider(for item: BaseItemDto) -> MediaPlayerItemProvider? {
        guard item.isPlayable else { return nil }

        return MediaPlayerItemProvider(item: item) { [weak self] item, modifyItem in
            let bitrate = await self?.manager?.playbackBitrate ?? Defaults[.VideoPlayer.Playback.appMaximumBitrate]
            return try await MediaPlayerItem.build(
                for: item,
                mediaSource: item.mediaSources?.first,
                requestedBitrate: bitrate,
                modifyItem: modifyItem
            )
        }
    }

    private struct PlaylistOverlay: View {

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @ObservedObject
        private var queue: PlaylistUpNextMediaPlayerQueue

        init(queue: PlaylistUpNextMediaPlayerQueue) {
            self.queue = queue
        }

        @ViewBuilder
        private var content: some View {
            if queue.isLoadingPlaylist {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable(false)
            } else if !queue.upcomingItems.isEmpty {
                CollectionHStack(
                    uniqueElements: queue.upcomingItems,
                    id: \.id,
                    layout: .grid(columns: 5, rows: 1, columnTrailingInset: 0)
                ) { item in
                    PosterButton(
                        item: item._withLandscapeImages { environment in
                            [item.imageSource(.primary, environment: environment)]
                        },
                        displayType: .landscape
                    ) { _ in
                        guard let provider = queue.makeProvider(for: item) else { return }
                        manager.playNewItem(provider: provider)
                    }
                }
                .ignoresSafeArea(.container, edges: .horizontal)
                .focusSection()
            }
        }

        var body: some View {
            content
        }
    }
}

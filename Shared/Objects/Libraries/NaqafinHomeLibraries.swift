//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import JellyfinAPI

/// Naqafin's Continue Watching source: standard Jellyfin items enriched by
/// Playlist Up Next candidates when that optional companion plugin is active.
struct NaqafinResumeItemsLibrary: BaseItemKindLibrary {

    let mediaTypes: [MediaType]
    let parent: TitledLibraryParent = .init(displayTitle: L10n.continue, id: "continue-watching")

    var libraryItemTypes: [BaseItemKind] {
        mediaTypes.flatMap(\.supportedNaqafinLibraryItemTypes)
    }

    init(mediaTypes: [MediaType] = [.video]) {
        self.mediaTypes = mediaTypes
    }

    func retrievePage(
        environment: Empty,
        pageState: LibraryPageState
    ) async throws -> [BaseItemDto] {
        var parameters = Paths.GetResumeItemsParameters()
        parameters.enableUserData = true
        parameters.fields = .MinimumFields
        parameters.limit = pageState.pageSize
        parameters.mediaTypes = mediaTypes
        parameters.startIndex = pageState.pageOffset
        parameters.userID = pageState.userSession.user.id

        let standardItems = try await pageState.userSession.client.send(Paths.getResumeItems(parameters: parameters)).value.items ?? []
        guard pageState.pageOffset == 0 else { return standardItems }

        let playlistEntries = try await pageState.userSession.naqafinPlaylistUpNextService.entries(playbackState: .resume)
        return pageState.userSession.naqafinPlaylistUpNextService.merge(standardItems, with: playlistEntries)
    }
}

/// Naqafin's Next Up source: standard Jellyfin episodes enriched by Playlist
/// Up Next candidates without turning playlists into a separate home shelf.
/// Series with an in-progress episode belong exclusively in Continue Watching.
struct NaqafinNextUpLibrary: BaseItemKindLibrary {

    struct Environment: WithDefaultValue {
        var enableRewatching: Bool
        var maxNextUp: TimeInterval

        static let `default`: Self = .init(
            enableRewatching: Defaults[.Customization.Home.resumeNextUp],
            maxNextUp: Defaults[.Customization.Home.maxNextUp]
        )
    }

    let libraryItemTypes: [BaseItemKind] = [.episode]
    let parent: TitledLibraryParent = .init(displayTitle: L10n.nextUp, id: "next-up")

    func retrievePage(
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> [BaseItemDto] {
        var parameters = Paths.GetNextUpParameters()
        parameters.enableRewatching = environment.enableRewatching
        parameters.enableUserData = true
        parameters.fields = .MinimumFields
        parameters.limit = pageState.pageSize
        parameters.startIndex = pageState.pageOffset

        if environment.maxNextUp > 0 {
            parameters.nextUpDateCutoff = Date.now.addingTimeInterval(-environment.maxNextUp)
        }

        let resumedSeriesIDs = try await resumedSeriesIDs(pageState: pageState)
        let standardItems = try await pageState.userSession.client.send(Paths.getNextUp(parameters: parameters)).value.items ?? []
        guard pageState.pageOffset == 0 else {
            return standardItems.filter { item in
                guard let seriesID = item.seriesID else { return true }
                return !resumedSeriesIDs.contains(seriesID)
            }
        }

        let playlistEntries = try await pageState.userSession.naqafinPlaylistUpNextService.entries(playbackState: .next)
        let items = pageState.userSession.naqafinPlaylistUpNextService.merge(standardItems, with: playlistEntries)
        return items.filter { item in
            guard let seriesID = item.seriesID else { return true }
            return !resumedSeriesIDs.contains(seriesID)
        }
    }

    private func resumedSeriesIDs(pageState: LibraryPageState) async throws -> Set<String> {
        var parameters = Paths.GetResumeItemsParameters()
        parameters.enableTotalRecordCount = false
        parameters.fields = .MinimumFields
        parameters.limit = 100
        parameters.mediaTypes = [.video]
        parameters.userID = pageState.userSession.user.id

        let standardItems = try await pageState.userSession.client.send(Paths.getResumeItems(parameters: parameters)).value.items ?? []
        let playlistEntries = try await pageState.userSession.naqafinPlaylistUpNextService.entries(
            playbackState: .resume,
            limit: 100
        )

        return Set((standardItems + playlistEntries.map(\.item)).compactMap(\.seriesID))
    }
}

private extension MediaType {

    var supportedNaqafinLibraryItemTypes: [BaseItemKind] {
        switch self {
        case .audio:
            [.audio, .musicAlbum]
        case .video:
            [.episode, .movie, .video]
        case .book:
            [.book]
        case .photo:
            [.photo]
        case .unknown:
            []
        }
    }
}

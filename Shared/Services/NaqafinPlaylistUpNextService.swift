//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import Get
import JellyfinAPI
import Logging

enum NaqafinPlaylistUpNextPlaybackState: String, Codable, Sendable {
    case next
    case resume
}

struct NaqafinPlaylistUpNextEntry: Codable, Sendable {

    let playlistID: String
    let playlistName: String
    let playlistIndex: Int
    let isExternalResumeItem: Bool
    let unplayedItemCount: Int
    let playbackState: NaqafinPlaylistUpNextPlaybackState
    let reason: String
    let lastPlayedDate: Date?
    let item: BaseItemDto

    private enum CodingKeys: String, CodingKey {
        case playlistID = "PlaylistId"
        case playlistName = "PlaylistName"
        case playlistIndex = "PlaylistIndex"
        case isExternalResumeItem = "IsExternalResumeItem"
        case unplayedItemCount = "UnplayedItemCount"
        case playbackState = "PlaybackState"
        case reason = "Reason"
        case lastPlayedDate = "LastPlayedDate"
        case item = "Item"
    }
}

private struct NaqafinPlaylistUpNextQueryResult: Decodable, Sendable {
    let items: [NaqafinPlaylistUpNextEntry]

    private enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct NaqafinPlaylistUpNextContext: Sendable {
    let playlistID: String
    let playlistName: String
    let playlistIndex: Int
    let isExternalResumeItem: Bool
    let playbackState: NaqafinPlaylistUpNextPlaybackState
    let unplayedItemCount: Int
}

@MainActor
final class NaqafinPlaylistUpNextContextStore {

    private var contexts: [String: NaqafinPlaylistUpNextContext] = [:]

    func context(for itemID: String?) -> NaqafinPlaylistUpNextContext? {
        guard let itemID else { return nil }
        return contexts[itemID]
    }

    func register(_ entries: [NaqafinPlaylistUpNextEntry]) {
        for entry in entries {
            guard let itemID = entry.item.id else { continue }
            contexts[itemID] = NaqafinPlaylistUpNextContext(
                playlistID: entry.playlistID,
                playlistName: entry.playlistName,
                playlistIndex: entry.playlistIndex,
                isExternalResumeItem: entry.isExternalResumeItem,
                playbackState: entry.playbackState,
                unplayedItemCount: entry.unplayedItemCount
            )
        }
    }

    func clear() {
        contexts.removeAll()
    }
}

@MainActor
final class NaqafinPlaylistUpNextService {

    private let logger = Logger.swiftfin()
    private let userSession: UserSession

    init(userSession: UserSession) {
        self.userSession = userSession
    }

    func entries(
        playbackState: NaqafinPlaylistUpNextPlaybackState,
        limit: Int = 24
    ) async throws -> [NaqafinPlaylistUpNextEntry] {
        let request = Request<NaqafinPlaylistUpNextQueryResult>(
            path: "/PlaylistUpNext/\(userSession.user.id)/Entries",
            query: [
                ("limit", String(limit)),
                ("playbackState", playbackState.rawValue),
            ],
            id: "NaqafinPlaylistUpNextEntries"
        )
        let response: Response<NaqafinPlaylistUpNextQueryResult>
        do {
            response = try await userSession.client.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug(
                "Playlist Up Next entries are unavailable; retaining the standard home row",
                metadata: ["error": .string(error.localizedDescription)]
            )
            return []
        }
        let entries = response.value.items.filter { entry in
            Defaults[.Customization.Home.includeAudioPlaylistItems] || entry.item.type != .audio
        }
        logger.debug(
            "Playlist Up Next entries loaded",
            metadata: [
                "playbackState": .string(playbackState.rawValue),
                "count": .stringConvertible(entries.count),
                "items": .string(entries.map(\.item.displayTitle).joined(separator: ", ")),
            ]
        )
        return entries
    }

    func merge(
        _ standardItems: [BaseItemDto],
        with playlistEntries: [NaqafinPlaylistUpNextEntry]
    ) -> [BaseItemDto] {
        userSession.naqafinPlaylistUpNextContextStore.register(playlistEntries)

        var playlistItemIDs = Set<String>()
        let prioritizedItems = playlistEntries
            .map(\.item)
            .filter { item in
                guard let itemID = item.id else { return false }
                return playlistItemIDs.insert(itemID).inserted
            }
        let replacedCount = prioritizedItems.count { playlistItem in
            standardItems.contains { $0.id == playlistItem.id }
        }
        let remainingStandardItems = standardItems.filter { item in
            guard let itemID = item.id else { return true }
            return !playlistItemIDs.contains(itemID)
        }

        logger.debug(
            "Playlist Up Next home merge completed",
            metadata: [
                "standardCount": .stringConvertible(standardItems.count),
                "playlistCount": .stringConvertible(playlistEntries.count),
                "prioritizedCount": .stringConvertible(prioritizedItems.count),
                "replacedCount": .stringConvertible(replacedCount),
                "remainingStandardCount": .stringConvertible(remainingStandardItems.count),
            ]
        )

        return prioritizedItems + remainingStandardItems
    }
}

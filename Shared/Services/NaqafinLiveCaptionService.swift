//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Get
import JellyfinAPI
import Logging

struct NaqafinLiveCaptionSession: Decodable, Sendable {

    let sessionID: String
    let liveVTTURL: String
    let pollSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "SessionId"
        case liveVTTURL = "LiveVttUrl"
        case pollSeconds = "PollSeconds"
    }
}

private struct StartNaqafinLiveCaptionSession: Encodable {
    let playSessionID: String
    let mediaSourceID: String?
    let audioStreamIndex: Int
    let positionTicks: Int64
    let language: String
    let enableOpenAIPolish: Bool
    let continueAfterPlaybackStops: Bool = false

    private enum CodingKeys: String, CodingKey {
        case playSessionID = "PlaySessionId"
        case mediaSourceID = "MediaSourceId"
        case audioStreamIndex = "AudioStreamIndex"
        case positionTicks = "PositionTicks"
        case language = "Language"
        case enableOpenAIPolish = "EnableOpenAiPolish"
        case continueAfterPlaybackStops = "ContinueAfterPlaybackStops"
    }
}

@MainActor
final class NaqafinLiveCaptionService {

    private let logger = Logger.swiftfin()
    private let userSession: UserSession
    private var activeSession: NaqafinLiveCaptionSession?
    private var activeItemID: String?
    private var playbackPosition: Duration = .zero
    private var refreshTask: Task<Void, Never>?

    init(userSession: UserSession) {
        self.userSession = userSession
    }

    func start(
        for item: MediaPlayerItem,
        position: Duration,
        language: String,
        enableOpenAIPolish: Bool,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> URL {
        guard userSession.naqafinFeatureService.snapshot.supportsLiveCaptions,
              let itemID = item.baseItem.id
        else {
            throw UserSessionError.missingCurrentSession
        }

        await stopIfNeeded()

        let request = Request<NaqafinLiveCaptionSession>(
            path: "/AutoGenerateCaptions/Items/\(itemID)/Sessions",
            method: .post,
            body: StartNaqafinLiveCaptionSession(
                playSessionID: item.playSessionID,
                mediaSourceID: item.mediaSource.id,
                audioStreamIndex: item.selectedAudioStreamIndex ?? 0,
                positionTicks: Int64(position.components.seconds * 10_000_000),
                language: language,
                enableOpenAIPolish: enableOpenAIPolish
            ),
            id: "NaqafinStartLiveCaptionSession"
        )
        let session = try await userSession.client.send(request).value
        guard isCurrent() else {
            let stopRequest = Request<Void>(
                path: "/AutoGenerateCaptions/Sessions/\(session.sessionID)/Stop",
                method: .post,
                id: "NaqafinStopStaleLiveCaptionSession"
            )
            _ = try? await userSession.client.send(stopRequest)
            throw CancellationError()
        }
        activeSession = session
        activeItemID = itemID
        playbackPosition = position
        logger.info("Started Naqafin Live caption session", metadata: ["itemID": .string(itemID)])
        refreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(session.pollSeconds))
                guard !Task.isCancelled,
                      self.activeSession?.sessionID == session.sessionID,
                      isCurrent()
                else { return }

                await self.reportPlaybackPosition(for: session)
            }
        }

        guard let liveVTTURL = liveVTTURL(for: session) else {
            await stopIfNeeded()
            throw URLError(.badURL)
        }
        return liveVTTURL
    }

    func updatePlaybackPosition(_ position: Duration, for itemID: String?) {
        guard itemID == activeItemID else { return }
        playbackPosition = position
    }

    func isActive(for itemID: String?) -> Bool {
        activeItemID == itemID
    }

    func stopIfNeeded(for itemID: String? = nil) async {
        guard let activeSession,
              itemID == nil || activeItemID == itemID
        else { return }

        refreshTask?.cancel()
        refreshTask = nil

        let request = Request<Void>(
            path: "/AutoGenerateCaptions/Sessions/\(activeSession.sessionID)/Stop",
            method: .post,
            id: "NaqafinStopLiveCaptionSession"
        )
        _ = try? await userSession.client.send(request)
        self.activeSession = nil
        activeItemID = nil
        playbackPosition = .zero
    }

    private func reportPlaybackPosition(for session: NaqafinLiveCaptionSession) async {
        let positionTicks = Int64(max(0, playbackPosition.seconds) * 10_000_000)
        let request = Request<Void>(
            path: "/AutoGenerateCaptions/Sessions/\(session.sessionID)/Position",
            method: .post,
            query: [("positionTicks", "\(positionTicks)")],
            id: "NaqafinReportLiveCaptionPosition"
        )
        _ = try? await userSession.client.send(request)
    }

    private func liveVTTURL(for session: NaqafinLiveCaptionSession) -> URL? {
        userSession.client.url(
            with: Request<Void>(
                path: session.liveVTTURL
            ),
            queryAPIKey: true
        )
    }
}

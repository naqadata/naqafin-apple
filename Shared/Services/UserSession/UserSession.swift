//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import Pulse

final class UserSession {

    let server: ServerState
    let user: UserState

    lazy var client: JellyfinClient = JellyfinClient(
        configuration: .swiftfinConfiguration(
            url: server.effectiveServerURL,
            accessToken: user.accessToken
        ),
        sessionConfiguration: .swiftfin,
        sessionDelegate: URLSessionProxyDelegate(logger: NetworkLogger.swiftfin())
    )

    @MainActor
    lazy var serverConnectionManager = ServerConnectionManager()

    @MainActor
    lazy var naqafinFeatureService = NaqafinFeatureService()

    @MainActor
    lazy var naqafinPlaylistUpNextContextStore = NaqafinPlaylistUpNextContextStore()

    @MainActor
    lazy var naqafinPlaylistUpNextService = NaqafinPlaylistUpNextService(userSession: self)

    @MainActor
    lazy var naqafinLiveCaptionService = NaqafinLiveCaptionService(userSession: self)

    lazy var serverSocketManager = ServerSocketManager()

    @MainActor
    private lazy var services: [any UserSessionService] = [
        serverConnectionManager,
        naqafinFeatureService,
        serverSocketManager,
    ]

    init(
        server: ServerState,
        user: UserState
    ) {
        self.server = server
        self.user = user
    }

    @MainActor
    func willStart() async {
        for service in services {
            await service.willStart(userSession: self)
        }
    }

    @MainActor
    func didStart() {
        for service in services {
            service.didStart(userSession: self)
        }
    }

    @MainActor
    func willStop() {
        Task { @MainActor [weak self] in
            await self?.naqafinLiveCaptionService.stopIfNeeded()
        }

        for service in services.reversed() {
            service.willStop(userSession: self)
        }
    }
}

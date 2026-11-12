//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import Get
import JellyfinAPI
import Logging

/// The server-side features which are safe to expose in Naqafin's UI.
///
/// A snapshot belongs to one authenticated `UserSession`; it is deliberately
/// not persisted so server plugin changes are reflected on the next login.
struct NaqafinFeatureSnapshot: Equatable, Sendable {

    static let unavailable = Self(
        hasAutoGenerateCaptions: false,
        hasPlaylistUpNext: false,
        hasCaptionCapabilities: false,
        captionCapabilities: .unavailable
    )

    let hasAutoGenerateCaptions: Bool
    let hasPlaylistUpNext: Bool
    let hasCaptionCapabilities: Bool
    let captionCapabilities: NaqafinCaptionCapabilities

    var supportsLiveCaptions: Bool {
        hasAutoGenerateCaptions && hasCaptionCapabilities
    }

    var supportsEnhancedCaptions: Bool {
        supportsLiveCaptions && captionCapabilities.enhancedCaptionsAvailable
    }
}

/// The compatibility boundary for Auto Generate Captions capability keys.
/// Keep server payload spelling here; callers use the semantic properties.
struct NaqafinCaptionCapabilities: Codable, Equatable, Sendable {

    static let unavailable = Self()

    let openAICaptionPolishAvailable: Bool
    let captionPolishAvailable: Bool
    let captionPolishProvider: String?
    let serverEnhancedQueueAvailable: Bool?
    let backgroundPrefetchAvailable: Bool?
    let backgroundDiarizationEnabled: Bool

    init(
        openAICaptionPolishAvailable: Bool = false,
        captionPolishAvailable: Bool = false,
        captionPolishProvider: String? = nil,
        serverEnhancedQueueAvailable: Bool? = nil,
        backgroundPrefetchAvailable: Bool? = nil,
        backgroundDiarizationEnabled: Bool = false
    ) {
        self.openAICaptionPolishAvailable = openAICaptionPolishAvailable
        self.captionPolishAvailable = captionPolishAvailable
        self.captionPolishProvider = captionPolishProvider
        self.serverEnhancedQueueAvailable = serverEnhancedQueueAvailable
        self.backgroundPrefetchAvailable = backgroundPrefetchAvailable
        self.backgroundDiarizationEnabled = backgroundDiarizationEnabled
    }

    /// Newer servers advertise `ServerEnhancedQueueAvailable`.  Older plugin
    /// builds used `BackgroundPrefetchAvailable`, which remains a fallback.
    var enhancedCaptionsAvailable: Bool {
        serverEnhancedQueueAvailable ?? backgroundPrefetchAvailable ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case openAICaptionPolishAvailable = "OpenAiCaptionPolishAvailable"
        case captionPolishAvailable = "CaptionPolishAvailable"
        case captionPolishProvider = "CaptionPolishProvider"
        case serverEnhancedQueueAvailable = "ServerEnhancedQueueAvailable"
        case backgroundPrefetchAvailable = "BackgroundPrefetchAvailable"
        case backgroundDiarizationEnabled = "BackgroundDiarizationEnabled"
    }
}

/// A successful response from the Playlist Up Next endpoint proves that the
/// optional plugin is available to the current user.  Plugin enumeration is
/// commonly restricted to administrators, while this endpoint is intended for
/// every signed-in library user.
private struct NaqafinPlaylistUpNextProbe: Decodable, Sendable {}

@MainActor
final class NaqafinFeatureService: ObservableObject, UserSessionService {

    @Published
    private(set) var snapshot = NaqafinFeatureSnapshot.unavailable

    private let logger = Logger.swiftfin()
    private weak var userSession: UserSession?
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func willStart(userSession: UserSession) async {
        self.userSession = userSession
        await refresh()
    }

    func willStop(userSession: UserSession) {
        refreshTask?.cancel()
        refreshTask = nil
        cancellables.removeAll()
        self.userSession = nil
        snapshot = .unavailable
    }

    func didStart(userSession: UserSession) {
        Notifications[.didChangeServerConnection]
            .publisher
            .sink { [weak self] _ in
                self?.refreshInBackground()
            }
            .store(in: &cancellables)
    }

    /// Refreshes the session-scoped snapshot. Failed discovery intentionally
    /// leaves the app in stock Swiftfin mode instead of surfacing dead controls.
    func refresh() async {
        guard let userSession else {
            snapshot = .unavailable
            return
        }

        let plugins = try? await userSession.client.send(Paths.getPlugins).value
        guard !Task.isCancelled else { return }

        let hasPlaylistUpNext = await hasPlaylistUpNext(for: userSession)

        // Plugin enumeration is commonly restricted to administrators.  The
        // capability route is available to normal playback users, so it is the
        // authoritative proof that this feature can be shown.
        let captionDiscovery = await captionCapabilities(for: userSession)
        let hasAutoGenerateCaptions = captionDiscovery.wasSuccessful

        logger.debug(
            "Naqafin companion discovery completed",
            metadata: [
                "autoGenerateCaptions": .stringConvertible(hasAutoGenerateCaptions),
                "playlistUpNext": .stringConvertible(hasPlaylistUpNext),
                "pluginListAvailable": .stringConvertible(plugins != nil),
            ]
        )

        guard !Task.isCancelled else { return }
        snapshot = .init(
            hasAutoGenerateCaptions: hasAutoGenerateCaptions,
            hasPlaylistUpNext: hasPlaylistUpNext,
            hasCaptionCapabilities: captionDiscovery.wasSuccessful,
            captionCapabilities: captionDiscovery.capabilities
        )
    }

    func refreshInBackground() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func hasPlaylistUpNext(for userSession: UserSession) async -> Bool {
        let request = Request<NaqafinPlaylistUpNextProbe>(
            path: "/PlaylistUpNext/\(userSession.user.id)/Entries",
            query: [
                ("limit", "1"),
                ("playbackState", "next"),
            ],
            id: "NaqafinPlaylistUpNextProbe"
        )

        do {
            _ = try await userSession.client.send(request).value
            logger.debug("Playlist Up Next probe succeeded")
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.debug(
                "Playlist Up Next is unavailable to the current user",
                metadata: ["error": .string(error.localizedDescription)]
            )
            return false
        }
    }

    private func captionCapabilities(for userSession: UserSession) async
    -> (wasSuccessful: Bool, capabilities: NaqafinCaptionCapabilities) {
        let request = Request<NaqafinCaptionCapabilities>(
            path: "/AutoGenerateCaptions/Capabilities",
            id: "NaqafinAutoGenerateCaptionsCapabilities"
        )

        do {
            let capabilities = try await userSession.client.send(request).value
            logger.debug("Auto Generate Captions capability probe succeeded")
            return (true, capabilities)
        } catch is CancellationError {
            return (false, .unavailable)
        } catch {
            logger.debug(
                "Auto Generate Captions is unavailable to the current user",
                metadata: ["error": .string(error.localizedDescription)]
            )
            return (false, .unavailable)
        }
    }
}

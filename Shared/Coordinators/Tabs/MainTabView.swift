//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

// TODO: fix weird tvOS icon rendering
struct MainTabView: View {

    @InjectedObject(\.userSessionManager)
    private var userSessionManager

    @StateObject
    private var tabCoordinator: TabCoordinator

    init() {
        _tabCoordinator = StateObject(wrappedValue: Self.defaultTabCoordinator)
    }

    private static var defaultTabCoordinator: TabCoordinator {
        #if os(iOS)
        TabCoordinator {
            TabItem.contentGroup(provider: DefaultContentGroupProvider())
            TabItem.search
            TabItem.media
        }
        #else
        TabCoordinator {
            TabItem.contentGroup(provider: DefaultContentGroupProvider())
            TabItem.library(
                title: L10n.tvShowsCapitalized,
                systemName: "tv",
                filters: .init(itemTypes: [.series])
            )
            TabItem.library(
                title: L10n.movies,
                systemName: "film",
                filters: .init(itemTypes: [.movie])
            )
            TabItem.search
            TabItem.media
            TabItem.settings
        }
        #endif
    }

    private func routePendingDeepLink(_ deepLink: DeepLink?) {
        guard let deepLink else { return }

        Task { @MainActor in
            let route = deepLink.route()
            await tabCoordinator.route(to: route)
        }
    }

    @ViewBuilder
    private func legacyTabContent() -> some View {
        TabView(selection: $tabCoordinator.selectedTabID) {
            ForEach(tabCoordinator.tabs, id: \.item.id) { tab in
                NavigationInjectionView(
                    coordinator: tab.coordinator
                ) {
                    #if os(tvOS)
                    FocusedPosterPlaybackHandler {
                        tab.item.content
                    }
                    #else
                    tab.item.content
                        .if(tabCoordinator.tabs.first?.item.id == tab.item.id) { view in
                            view.topBarTrailing {
                                FirstTabSettingsBarButton()
                            }
                        }
                    #endif
                }
                .environmentObject(tabCoordinator)
                .environment(\.tabItemSelected, tab.publisher)
                .tabItem {
                    Label(
                        tab.item.displayTitle,
                        systemImage: tab.item.systemImage
                    )
                    .labelStyle(tab.item.labelStyle)
                    .symbolRenderingMode(.monochrome)
                    .eraseToAnyView()
                }
                .tag(tab.item.id)
            }
        }
    }

    @available(iOS 18.0, tvOS 18.0, *)
    @ViewBuilder
    private func tabContent() -> some View {
        TabView(selection: $tabCoordinator.selectedTabID) {
            ForEach(tabCoordinator.tabs, id: \.item.id) { tab in
                Tab(
                    value: tab.item.id,
                    role: tab.item.id == TabItem.search.id ? .search : nil
                ) {
                    NavigationInjectionView(
                        coordinator: tab.coordinator
                    ) {
                        #if os(tvOS)
                        FocusedPosterPlaybackHandler {
                            tab.item.content
                        }
                        #else
                        tab.item.content
                            .if(tabCoordinator.tabs.first?.item.id == tab.item.id) { view in
                                view.topBarTrailing {
                                    FirstTabSettingsBarButton()
                                }
                            }
                        #endif
                    }
                    .environmentObject(tabCoordinator)
                    .environment(\.tabItemSelected, tab.publisher)
                } label: {
                    Label(
                        tab.item.displayTitle,
                        systemImage: tab.item.systemImage
                    )
                    #if os(tvOS)
                    .labelStyle(.titleOnly)
                    #endif
                    .symbolRenderingMode(.monochrome)
                }
            }
        }
        #if os(tvOS)
        .tabViewStyle(.tabBarOnly)
        #endif
    }

    var body: some View {
        Group {
            if #available(iOS 18, tvOS 18.0, *) {
                tabContent()
            } else {
                legacyTabContent()
            }
        }
        .backport
        .onChange(of: userSessionManager.pendingDeepLink) {
            routePendingDeepLink(userSessionManager.consumePendingDeepLink())
        }
        #if os(tvOS)
        .background(alignment: .top) {
            FocusedPosterCinematicBackgroundView()
        }
        #endif
    }
}

#if os(tvOS)
private struct FocusedPosterPlaybackHandler<Content: View>: View {

    @FocusedValue(\.focusedPoster)
    private var focusedPoster

    @Router
    private var router

    @ViewBuilder
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private func playFocusedPoster() {
        guard router.isRootOfPath,
              let item = focusedPoster?._poster as? BaseItemDto,
              item.presentPlayButton
        else { return }

        Task { @MainActor in
            let provider = ItemContentGroupProvider(item: item)

            do {
                _ = try await provider.makeGroups(environment: .init())

                guard let mediaPlayerItemProvider = provider.mediaPlayerItemProvider else {
                    provider.logger.error("Play selected with no playback item provider")
                    return
                }

                let queue: (any MediaPlayerQueue)? = if let playlistContext = provider.playlistUpNextContext,
                                                        let itemID = mediaPlayerItemProvider.item.id
                {
                    PlaylistUpNextMediaPlayerQueue(context: playlistContext, initialItemID: itemID)
                } else if mediaPlayerItemProvider.item.type == .episode {
                    EpisodeMediaPlayerQueue(episode: mediaPlayerItemProvider.item)
                } else {
                    nil
                }

                router.route(
                    to: .videoPlayer(
                        provider: mediaPlayerItemProvider,
                        queue: queue
                    )
                )
            } catch {
                provider.logger.error("Unable to resolve focused poster for playback: \(error)")
            }
        }
    }

    var body: some View {
        content
            .onPlayPauseCommand(perform: playFocusedPoster)
    }
}
#endif

#if os(iOS)
private struct FirstTabSettingsBarButton: View {

    @Injected(\.currentUserSession)
    private var userSession

    @Router
    private var router

    var body: some View {
        if router.isRootOfPath,
           let userSession
        {
            SettingsBarButton(
                server: userSession.server,
                user: userSession.user
            ) {
                router.route(to: .settings)
            }
        }
    }
}
#endif

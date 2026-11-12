//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

extension VideoPlayer.PlaybackControls.Toolbar.ActionButtons {

    enum PlaybackActionMenuPage: Hashable {
        case audio
        case speed
        case quality
        case subtitles

        var title: String {
            switch self {
            case .audio: L10n.audio
            case .speed: L10n.playbackSpeed
            case .quality: L10n.playbackQuality
            case .subtitles: L10n.subtitles
            }
        }

        var systemImage: String {
            switch self {
            case .audio: VideoPlayerActionButton.audio.systemImage
            case .speed: VideoPlayerActionButton.playbackSpeed.systemImage
            case .quality: VideoPlayerActionButton.playbackSettings.systemImage
            case .subtitles: VideoPlayerActionButton.subtitles.systemImage
            }
        }
    }

    struct PlaybackActionMenuButton: View {

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState

        let page: PlaybackActionMenuPage

        var body: some View {
            Button {
                containerState.isPresentingPlaybackActionMenu = true
            } label: {
                Label(page.title, systemImage: page.systemImage)
            }
        }
    }

    struct LiveCaptionAutoStarter: View {

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @State
        private var attemptedPlaybackSessionID: String?

        private var supportsLiveCaptions: Bool {
            Container.shared.currentUserSession()?.naqafinFeatureService.snapshot.supportsLiveCaptions == true
                && manager.proxy is VLCMediaPlayerProxy
        }

        private func startIfNeeded() {
            guard let playbackItem = manager.playbackItem,
                  attemptedPlaybackSessionID != playbackItem.playSessionID,
                  supportsLiveCaptions,
                  playbackItem.subtitleStreams.isEmpty,
                  !(playbackItem.selectedSubtitleStreamIndex.map { $0 >= 0 } ?? false),
                  let userSession = Container.shared.currentUserSession(),
                  !userSession.naqafinLiveCaptionService.isActive(for: playbackItem.baseItem.id),
                  let proxy = manager.proxy as? VLCMediaPlayerProxy
            else { return }

            attemptedPlaybackSessionID = playbackItem.playSessionID

            Task {
                do {
                    let url = try await userSession.naqafinLiveCaptionService.start(
                        for: playbackItem,
                        position: manager.seconds,
                        language: Defaults[.VideoPlayer.GeneratedCaptions.language],
                        enableOpenAIPolish: Defaults[.VideoPlayer.GeneratedCaptions.openAIPolish],
                        isCurrent: {
                            manager.playbackItem?.playSessionID == playbackItem.playSessionID
                        }
                    )
                    proxy.addLiveCaptionTrack(url: url)
                } catch {
                    await manager.error(error)
                }
            }
        }

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .onAppear(perform: startIfNeeded)
                .onChange(of: manager.playbackItem?.playSessionID) {
                    startIfNeeded()
                }
        }
    }

    struct PlaybackActionMenuOverlay: View {

        private struct MenuRowButtonStyle: ButtonStyle {

            @Environment(\.isFocused)
            private var isFocused

            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .foregroundStyle(isFocused ? Color.black : .primary)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isFocused ? .white : .clear)
                    }
                    .scaleEffect(configuration.isPressed ? 0.98 : 1)
                    .animation(.easeInOut(duration: 0.12), value: isFocused)
                    .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
            }
        }

        @Default(.VideoPlayer.Playback.rates)
        private var rates: [Float]

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager
        @Router
        private var router

        @Default(.VideoPlayer.GeneratedCaptions.language)
        private var generatedCaptionLanguage
        @Default(.VideoPlayer.GeneratedCaptions.openAIPolish)
        private var generatedCaptionOpenAIPolish

        @FocusState
        private var focusedPage: PlaybackActionMenuPage?
        @FocusState
        private var focusedRowID: String?

        @State
        private var page: PlaybackActionMenuPage?

        private var rootPages: [PlaybackActionMenuPage] {
            var pages: [PlaybackActionMenuPage] = []
            if manager.playbackItem?.audioStreams.isEmpty == false {
                pages.append(.audio)
            }
            if manager.playbackItem?.subtitleStreams.isEmpty == false || supportsLiveCaptions {
                pages.append(.subtitles)
            }
            pages.append(.speed)
            pages.append(.quality)
            return pages
        }

        private func dismiss() {
            containerState.isPresentingPlaybackActionMenu = false
        }

        private func select(_ page: PlaybackActionMenuPage) {
            self.page = page
            focusFirstDetailRow()
        }

        private func showRootPage() {
            page = nil

            Task { @MainActor in
                await Task.yield()
                focusedRowID = nil
                focusedPage = rootPages.first
            }
        }

        private var firstDetailRowID: String? {
            guard let playbackItem = manager.playbackItem else { return nil }

            switch page {
            case .audio:
                return playbackItem.audioStreams.first.map { "audio-\($0.index ?? -1)" }
            case .speed:
                return rates.first.map { "speed-\($0)" }
            case .quality:
                let sources = playbackItem.baseItem.mediaSources ?? []
                if sources.count > 1, let source = sources.first {
                    return "source-\(source.id ?? "unknown")"
                }
                return playbackItem.mediaSource.supportedBitrates.first.map { "bitrate-\($0.rawValue)" }
            case .subtitles:
                return "subtitle-none"
            case nil:
                return nil
            }
        }

        private func focusFirstDetailRow() {
            Task { @MainActor in
                await Task.yield()
                focusedPage = nil
                focusedRowID = firstDetailRowID
            }
        }

        private var supportsLiveCaptions: Bool {
            Container.shared.currentUserSession()?.naqafinFeatureService.snapshot.supportsLiveCaptions == true
                && manager.proxy is VLCMediaPlayerProxy
        }

        private func isLiveCaptionSelected(for playbackItem: MediaPlayerItem) -> Bool {
            Container.shared.currentUserSession()?
                .naqafinLiveCaptionService
                .isActive(for: playbackItem.baseItem.id) == true
        }

        private func supportsSubtitleAdjustments(for playbackItem: MediaPlayerItem) -> Bool {
            guard manager.proxy is MediaPlayerOffsetConfigurable,
                  manager.proxy is MediaPlayerSubtitleConfigurable
            else { return false }

            if isLiveCaptionSelected(for: playbackItem) {
                return true
            }

            return playbackItem.subtitleStreams.contains {
                $0.index == playbackItem.selectedSubtitleStreamIndex
                    && $0.isTextSubtitleStream == true
            }
        }

        private func startLiveCaption(for playbackItem: MediaPlayerItem) {
            Task {
                guard let userSession = Container.shared.currentUserSession(),
                      let proxy = manager.proxy as? VLCMediaPlayerProxy
                else { return }

                do {
                    let url = try await userSession.naqafinLiveCaptionService.start(
                        for: playbackItem,
                        position: manager.seconds,
                        language: generatedCaptionLanguage,
                        enableOpenAIPolish: generatedCaptionOpenAIPolish,
                        isCurrent: {
                            manager.playbackItem?.playSessionID == playbackItem.playSessionID
                        }
                    )
                    proxy.addLiveCaptionTrack(url: url)
                    dismiss()
                } catch {
                    await manager.error(error)
                }
            }
        }

        private func searchForSubtitles(for playbackItem: MediaPlayerItem) {
            let originalSubtitleIndexes = Set(playbackItem.subtitleStreams.compactMap(\.index))
            let playbackSessionID = playbackItem.playSessionID
            let viewModel = ItemSubtitlesViewModel(item: playbackItem.baseItem)

            dismiss()
            router.route(to: .searchSubtitle(viewModel: viewModel) { subtitles in
                guard self.manager.playbackItem?.playSessionID == playbackSessionID else { return }
                let index = subtitles.last {
                    $0.isTextSubtitleStream == true
                        && $0.index.map { !originalSubtitleIndexes.contains($0) } == true
                }?.index
                self.manager.reloadCurrentItem(selectingSubtitleStreamIndex: index)
            })
        }

        private func row(
            id: String,
            selected: Bool = false,
            action: @escaping () -> Void,
            @ViewBuilder label: () -> some View
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    label()
                    Spacer(minLength: 12)
                    if selected {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 20)
            }
            .buttonStyle(MenuRowButtonStyle())
            .focusEffectDisabled()
            .focused($focusedRowID, equals: id)
        }

        private var rootContent: some View {
            VStack(spacing: 4) {
                ForEach(rootPages, id: \.self) { page in
                    Button {
                        select(page)
                    } label: {
                        Label(page.title, systemImage: page.systemImage)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .padding(.horizontal, 20)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.right")
                                    .fontWeight(.semibold)
                                    .padding(.trailing, 20)
                            }
                    }
                    .buttonStyle(MenuRowButtonStyle())
                    .focusEffectDisabled()
                    .focused($focusedPage, equals: page)
                }
            }
            .backport
            .defaultFocus($focusedPage, rootPages.first, priority: .userInitiated)
        }

        @ViewBuilder
        private var detailContent: some View {
            switch page {
            case .audio:
                audioContent
            case .speed:
                speedContent
            case .quality:
                qualityContent
            case .subtitles:
                subtitlesContent
            case nil:
                EmptyView()
            }
        }

        private var audioContent: some View {
            VStack(spacing: 4) {
                if let playbackItem = manager.playbackItem {
                    ForEach(playbackItem.audioStreams, id: \.index) { stream in
                        row(
                            id: "audio-\(stream.index ?? -1)",
                            selected: playbackItem.selectedAudioStreamIndex == stream.index
                        ) {
                            playbackItem.selectedAudioStreamIndex = stream.index
                            dismiss()
                        } label: {
                            Text(stream.displayTitle ?? L10n.unknown)
                        }
                    }
                }
            }
        }

        private var speedContent: some View {
            VStack(spacing: 4) {
                ForEach(rates, id: \.self) { rate in
                    row(id: "speed-\(rate)", selected: manager.rate == rate) {
                        manager.rate = rate
                        dismiss()
                    } label: {
                        Text(rate, format: .playbackRate)
                    }
                }
            }
        }

        private var qualityContent: some View {
            VStack(spacing: 4) {
                if let playbackItem = manager.playbackItem {
                    let sources = playbackItem.baseItem.mediaSources ?? []
                    if sources.count > 1 {
                        Text(L10n.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                        ForEach(sources, id: \.id) { source in
                            row(id: "source-\(source.id ?? "unknown")", selected: source.id == playbackItem.mediaSource.id) {
                                guard source.id != playbackItem.mediaSource.id else { return }
                                manager.playNewItem(provider: provider(for: source, playbackItem: playbackItem))
                                dismiss()
                            } label: {
                                Text(source.displayTitle)
                            }
                        }
                    }

                    let bitrates = playbackItem.mediaSource.supportedBitrates
                    if bitrates.isNotEmpty {
                        Text(L10n.playbackQuality)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, sources.count > 1 ? 12 : 8)
                        ForEach(bitrates, id: \.rawValue) { bitrate in
                            row(id: "bitrate-\(bitrate.rawValue)", selected: bitrate == playbackItem.requestedBitrate) {
                                manager.setBitrate(bitrate: bitrate)
                                dismiss()
                            } label: {
                                Text(bitrate.displayTitle)
                            }
                        }
                    }
                }
            }
        }

        private var subtitlesContent: some View {
            VStack(spacing: 4) {
                if let playbackItem = manager.playbackItem {
                    row(id: "subtitle-none", selected: playbackItem.selectedSubtitleStreamIndex == nil) {
                        playbackItem.selectedSubtitleStreamIndex = nil
                        Task {
                            await Container.shared.currentUserSession()?
                                .naqafinLiveCaptionService.stopIfNeeded(for: playbackItem.baseItem.id)
                        }
                        dismiss()
                    } label: {
                        Text(L10n.none)
                    }

                    ForEach(playbackItem.subtitleStreams, id: \.index) { stream in
                        row(
                            id: "subtitle-\(stream.index ?? -1)",
                            selected: playbackItem.selectedSubtitleStreamIndex == stream.index
                        ) {
                            playbackItem.selectedSubtitleStreamIndex = stream.index
                            Task {
                                await Container.shared.currentUserSession()?
                                    .naqafinLiveCaptionService.stopIfNeeded(for: playbackItem.baseItem.id)
                            }
                            dismiss()
                        } label: {
                            Text(stream.displayTitle ?? L10n.unknown)
                        }
                    }

                    if supportsLiveCaptions {
                        row(id: "subtitle-live", selected: isLiveCaptionSelected(for: playbackItem)) {
                            startLiveCaption(for: playbackItem)
                        } label: {
                            Text("AI Generated (Live)")
                        }
                    }

                    if supportsSubtitleAdjustments(for: playbackItem) {
                        Divider().padding(.vertical, 6)
                        row(id: "subtitle-offset") {
                            dismiss()
                            containerState.isPresentingSubtitleOffset = true
                        } label: {
                            Label("Subtitle Offset", systemImage: "slider.horizontal.3")
                        }
                        row(id: "subtitle-size") {
                            dismiss()
                            containerState.isPresentingSubtitleFontSize = true
                        } label: {
                            Label("Font Size", systemImage: "textformat.size")
                        }
                    }

                    if playbackItem.baseItem.canEditSubtitles {
                        row(id: "subtitle-find") {
                            searchForSubtitles(for: playbackItem)
                        } label: {
                            Label("Find Subtitles…", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }

        private func provider(for mediaSource: MediaSourceInfo, playbackItem: MediaPlayerItem) -> MediaPlayerItemProvider {
            var item = playbackItem.baseItem
            item.userData?.playbackPositionTicks = manager.seconds.ticks
            let bitrate = playbackItem.requestedBitrate
            return MediaPlayerItemProvider(item: item, mediaSource: mediaSource) { baseItem, modifyItem in
                try await MediaPlayerItem.build(
                    for: baseItem,
                    mediaSource: mediaSource,
                    requestedBitrate: bitrate,
                    modifyItem: modifyItem
                )
            }
        }

        var body: some View {
            VStack(spacing: 12) {
                HStack {
                    if page != nil {
                        Button {
                            showRootPage()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                    }

                    Text(page?.title ?? L10n.menu)
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Group {
                    if page == nil {
                        rootContent
                    } else {
                        detailContent
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(width: 480)
            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .focusSection()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 54)
            .padding(.bottom, 150)
            .onAppear {
                showRootPage()
            }
            .onMoveCommand { direction in
                if direction == .left, page != nil {
                    showRootPage()
                }
            }
        }
    }
}

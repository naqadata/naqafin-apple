//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import SwiftUI

extension VideoPlayer.PlaybackControls.Toolbar.ActionButtons {

    struct Subtitles: View {

        private enum Selection: Hashable {
            case none
            case stream(Int)
            case live
        }

        @ViewContextContains(.isInMenu)
        private var isInMenu

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState

        @Router
        private var router

        @State
        private var selectedSubtitleStreamIndex: Int?

        @State
        private var isLiveCaptionSelected = false

        @State
        private var subtitleSelection: Selection = .none

        @Default(.VideoPlayer.GeneratedCaptions.language)
        private var generatedCaptionLanguage

        @Default(.VideoPlayer.GeneratedCaptions.openAIPolish)
        private var generatedCaptionOpenAIPolish

        private var supportsLiveCaptions: Bool {
            Container.shared.currentUserSession()?
                .naqafinFeatureService.snapshot.supportsLiveCaptions == true
                && manager.proxy is VLCMediaPlayerProxy
        }

        private var systemImage: String {
            if selectedSubtitleStreamIndex == nil, !isLiveCaptionSelected {
                VideoPlayerActionButton.subtitles.secondarySystemImage
            } else {
                VideoPlayerActionButton.subtitles.systemImage
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
                    isLiveCaptionSelected = true
                    subtitleSelection = .live
                } catch {
                    await manager.error(error)
                }
            }
        }

        private func stopLiveCaption(for playbackItem: MediaPlayerItem) {
            Task {
                await Container.shared.currentUserSession()?
                    .naqafinLiveCaptionService.stopIfNeeded(for: playbackItem.baseItem.id)
            }
        }

        private func shouldAutoStartLiveCaption(for playbackItem: MediaPlayerItem) -> Bool {
            supportsLiveCaptions
                && playbackItem.subtitleStreams.isEmpty
                && !(playbackItem.selectedSubtitleStreamIndex.map { $0 >= 0 } ?? false)
                && !isLiveCaptionSelected
        }

        private func supportsSubtitleOffset(for playbackItem: MediaPlayerItem) -> Bool {
            guard manager.proxy is MediaPlayerOffsetConfigurable,
                  manager.proxy is MediaPlayerSubtitleConfigurable
            else { return false }

            if isLiveCaptionSelected {
                return true
            }

            return playbackItem.subtitleStreams.contains {
                $0.index == playbackItem.selectedSubtitleStreamIndex
                    && $0.isTextSubtitleStream == true
            }
        }

        private func searchForSubtitles(for playbackItem: MediaPlayerItem) {
            let originalSubtitleIndexes = Set(playbackItem.subtitleStreams.compactMap(\.index))
            let playbackSessionID = playbackItem.playSessionID
            let viewModel = ItemSubtitlesViewModel(item: playbackItem.baseItem)

            router.route(to: .searchSubtitle(viewModel: viewModel) { subtitles in
                guard self.manager.playbackItem?.playSessionID == playbackSessionID else { return }

                let downloadedSubtitleIndex = subtitles.last {
                    $0.isTextSubtitleStream == true
                        && $0.index.map { !originalSubtitleIndexes.contains($0) } == true
                }?.index

                self.manager.reloadCurrentItem(selectingSubtitleStreamIndex: downloadedSubtitleIndex)
            })
        }

        @ViewBuilder
        private func subtitleOffset(for playbackItem: MediaPlayerItem) -> some View {
            if supportsSubtitleOffset(for: playbackItem) {
                Button("Subtitle Offset", systemImage: "slider.horizontal.3") {
                    containerState.isPresentingSubtitleOffset = true
                }

                Button("Font Size", systemImage: "textformat.size") {
                    containerState.isPresentingSubtitleFontSize = true
                }
            }
        }

        @ViewBuilder
        private func content(playbackItem: MediaPlayerItem) -> some View {
            Picker(L10n.subtitles, selection: $subtitleSelection) {
                Text(L10n.none).tag(Selection.none)
                ForEach(playbackItem.subtitleStreams, id: \.index) { stream in
                    Text(stream.displayTitle ?? L10n.unknown)
                        .tag(Selection.stream(stream.index ?? -1))
                }
                if supportsLiveCaptions {
                    Text("AI Generated (Live)").tag(Selection.live)
                }
            }

            if isLiveCaptionSelected {
                Picker("Generated caption language", selection: $generatedCaptionLanguage) {
                    Text("Auto").tag("auto")
                    Text("English").tag("en")
                }

                if Container.shared.currentUserSession()?.naqafinFeatureService.snapshot.captionCapabilities
                    .openAICaptionPolishAvailable == true
                {
                    Toggle("OpenAI polish", isOn: $generatedCaptionOpenAIPolish)
                }
            }

            subtitleOffset(for: playbackItem)

            if playbackItem.baseItem.canEditSubtitles {
                Button("Find Subtitles…", systemImage: "magnifyingglass") {
                    searchForSubtitles(for: playbackItem)
                }
            }
        }

        var body: some View {
            if let playbackItem = manager.playbackItem {
                Menu {
                    if isInMenu {
                        content(playbackItem: playbackItem)
                    } else {
                        Section(L10n.subtitles) {
                            content(playbackItem: playbackItem)
                        }
                    }
                } label: {
                    Label(L10n.subtitles, systemImage: systemImage)
                }
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary, .secondary)
                .videoPlayerActionButtonTransition()
                .onFirstAppear {
                    let initialSubtitleStreamIndex = playbackItem.selectedSubtitleStreamIndex
                        .flatMap { $0 >= 0 ? $0 : nil }
                    selectedSubtitleStreamIndex = initialSubtitleStreamIndex
                    subtitleSelection = initialSubtitleStreamIndex
                        .map(Selection.stream) ?? .none

                    if shouldAutoStartLiveCaption(for: playbackItem) {
                        startLiveCaption(for: playbackItem)
                    }
                }
                .backport
                .onChange(of: subtitleSelection) { _, selection in
                    switch selection {
                    case .live:
                        guard !isLiveCaptionSelected else { return }
                        startLiveCaption(for: playbackItem)
                    case .none:
                        selectedSubtitleStreamIndex = nil
                        playbackItem.selectedSubtitleStreamIndex = nil
                        isLiveCaptionSelected = false
                        stopLiveCaption(for: playbackItem)
                    case let .stream(index):
                        selectedSubtitleStreamIndex = index
                        playbackItem.selectedSubtitleStreamIndex = index
                        isLiveCaptionSelected = false
                        stopLiveCaption(for: playbackItem)
                    }
                }
            }
        }
    }
}

struct SubtitleOffsetView: View {

    private enum FocusTarget: Hashable {
        case offset
        case resetOffset
        case done
    }

    @Binding
    private var subtitleOffset: Duration

    private let dismiss: () -> Void

    @FocusState
    private var focusedTarget: FocusTarget?

    init(
        subtitleOffset: Binding<Duration>,
        dismiss: @escaping () -> Void
    ) {
        self._subtitleOffset = subtitleOffset
        self.dismiss = dismiss
    }

    private var offsetSliderValue: Binding<Double> {
        Binding(
            get: { subtitleOffset.seconds + 5 },
            set: { subtitleOffset = .seconds((($0 - 5) * 10).rounded() / 10) }
        )
    }

    private var offsetLabel: String {
        let milliseconds = Int((subtitleOffset.seconds * 1000).rounded())
        if milliseconds == 0 {
            return "None"
        }
        return String(format: "%+d ms", milliseconds)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 42) {
                Text("Subtitle Offset")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Subtitle Offset")
                        Spacer()
                        Text(offsetLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    SubtitleControlSlider(
                        value: offsetSliderValue,
                        total: 10,
                        step: 0.1
                    )
                    .frame(height: 48)
                    .focused($focusedTarget, equals: .offset)

                    HStack {
                        Text("-5 s")
                        Spacer()
                        Text("+5 s")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Reset Offset") {
                        subtitleOffset = .zero
                    }
                    .focused($focusedTarget, equals: .resetOffset)
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedTarget, equals: .done)
            }
            .frame(width: 760)
            .padding(52)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            .focusSection()
            .defaultFocus($focusedTarget, .offset)
            .onAppear {
                focusedTarget = .offset
            }
        }
    }
}

struct SubtitleFontSizeView: View {

    private enum FocusTarget: Hashable {
        case size
        case done
    }

    @Binding
    private var subtitleSize: Int

    private let onSizeChanged: (Int) -> Void
    private let dismiss: () -> Void

    @FocusState
    private var focusedTarget: FocusTarget?

    init(
        subtitleSize: Binding<Int>,
        onSizeChanged: @escaping (Int) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self._subtitleSize = subtitleSize
        self.onSizeChanged = onSizeChanged
        self.dismiss = dismiss
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(subtitleSize - 1) },
            set: { newValue in
                let size = Int(newValue.rounded()) + 1
                subtitleSize = size
                onSizeChanged(size)
            }
        )
    }

    private var sizeLabel: String {
        switch Int(sliderValue.wrappedValue.rounded()) {
        case 0 ... 3: "Extra Small"
        case 4 ... 7: "Small"
        case 8 ... 11: "Medium"
        case 12 ... 15: "Large"
        default: "Extra Large"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 42) {
                Text("Font Size")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Subtitle Font Size")
                        Spacer()
                        Text(sizeLabel)
                            .foregroundStyle(.secondary)
                    }

                    SubtitleControlSlider(value: sliderValue, total: 19, step: 1)
                        .frame(height: 48)
                        .focused($focusedTarget, equals: .size)

                    HStack {
                        Text("Smaller")
                        Spacer()
                        Text("Larger")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedTarget, equals: .done)
            }
            .frame(width: 760)
            .padding(52)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            .focusSection()
            .defaultFocus($focusedTarget, .size)
            .onAppear {
                focusedTarget = .size
            }
        }
    }
}

private struct SubtitleControlSlider: View {

    @Binding
    private var value: Double

    private let step: Double
    private let total: Double

    @FocusState
    private var isFocused: Bool

    init(value: Binding<Double>, total: Double, step: Double) {
        self._value = value
        self.total = total
        self.step = step
    }

    var body: some View {
        Button {} label: {
            ProgressView(value: value, total: total)
                .progressViewStyle(PlaybackProgressViewStyle(cornerStyle: .round))
                .overlay {
                    Capsule()
                        .stroke(.white, lineWidth: 4)
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(isFocused ? 1.04 : 1)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                value = max(0, value - step)
            case .right:
                value = min(total, value + step)
            default:
                break
            }
        }
    }
}

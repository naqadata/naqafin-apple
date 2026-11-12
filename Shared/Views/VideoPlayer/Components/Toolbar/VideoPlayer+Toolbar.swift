//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension VideoPlayer.PlaybackControls {

    struct Toolbar: View {

        static let buttonSize: CGFloat = UIDevice.isTV ? 56 : 44
        static let supplementButtonSpacing: CGFloat = UIDevice.isTV ? 20 : 10

        static var buttonSpacing: CGFloat {
            if #available(iOS 26.0, *) {
                supplementButtonSpacing
            } else {
                UIDevice.isTV ? 16 : 0
            }
        }

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        @Router
        private var router

        private var fontSize: CGFloat {
            UIDevice.isTV ? 30 : 24
        }

        private func onPressed(isPressed: Bool) {
            if isPressed {
                containerState.timer.stop()
            } else {
                containerState.timer.poke()
            }
        }

        @ViewBuilder
        private var closeButton: some View {
            Button {
                if containerState.isPresentingSupplement {
                    containerState.select(supplement: nil)
                } else {
                    manager.stop()
                    router.dismiss()
                }
            } label: {
                AlternateLayoutView {
                    Image(systemName: "xmark")
                } content: {
                    Label(
                        L10n.close,
                        systemImage: containerState.isPresentingSupplement ? "chevron.down" : "xmark"
                    )
                }
                .contentShape(Rectangle())
            }
        }

        var body: some View {
            HStack(alignment: UIDevice.isTV ? .bottom : .center) {

                if !UIDevice.isTV {
                    closeButton
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                }

                TitleView(item: manager.item)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Self.buttonSpacing) {
                    #if os(tvOS)
                    MediaSegmentSkipButton()
                    #endif

                    ActionButtons()
                        .modifier(
                            OverlayButtonStyleModifier(
                                onPressed: onPressed,
                                glassButtonSize: UIDevice.isTV ? 48 : nil
                            )
                        )
                }
                .frame(height: Self.buttonSize)
                .padding(.horizontal)
            }
            .font(.system(size: fontSize, weight: .semibold))
            .labelStyle(.iconOnly)
            #if os(iOS)
                .background {
                    EmptyHitTestView()
                }
            #endif
        }
    }
}

extension VideoPlayer.PlaybackControls.Toolbar {

    struct TitleView: PlatformView {

        @State
        private var subtitleContentSize: CGSize = .zero

        let item: BaseItemDto

        private var _titleSubtitle: (title: String, subtitle: String?) {
            if item.type == .episode {
                if let parentTitle = item.parentTitle {
                    return (title: parentTitle, subtitle: item.seasonEpisodeLabel)
                }
            }

            return (title: item.displayTitle, subtitle: nil)
        }

        @ViewBuilder
        private func _subtitle(_ subtitle: String) -> some View {
            Text(subtitle)
                .font(UIDevice.isTV ? .caption : .subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .trackingSize($subtitleContentSize)
        }

        var iOSView: some View {
            Text(_titleSubtitle.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomLeading) {
                    if let subtitle = _titleSubtitle.subtitle {
                        _subtitle(subtitle)
                            .lineLimit(1)
                            .offset(y: subtitleContentSize.height)
                    }
                }
        }

        var tvOSView: some View {
            VStack(alignment: .leading) {
                if let subtitle = _titleSubtitle.subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .fontWeight(.medium)
                }

                Text(_titleSubtitle.title)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .lineLimit(1)
        }
    }
}

#if os(tvOS)
extension VideoPlayer.PlaybackControls.Toolbar {

    struct MediaSegmentSkipButton: View {

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState

        @FocusState
        private var isFocused: Bool

        var body: some View {
            if containerState.shouldShowMediaSegmentSkipButton,
               let title = containerState.mediaSegmentSkipTitle,
               let countdown = containerState.mediaSegmentCountdown
            {
                Button {
                    containerState.skipMediaSegment()
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .lineLimit(1)

                        Text(countdown.description)
                            .monospacedDigit()
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.18), in: Circle())
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 172, height: VideoPlayer.PlaybackControls.Toolbar.buttonSize)
                }
                .buttonStyle(
                    NaqafinCapsuleButtonStyle(
                        isFocused: isFocused,
                        expandsToAvailableWidth: false,
                        unfocusedFill: Color.black.opacity(0.55),
                        unfocusedForeground: .white
                    )
                )
                .focused($isFocused)
                .onAppear {
                    isFocused = true
                }
            }
        }
    }
}
#endif

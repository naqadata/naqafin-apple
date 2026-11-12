//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

#if os(tvOS)
extension ButtonStyle where Self == SupplementActionButtonStyle {

    static var supplementAction: SupplementActionButtonStyle {
        SupplementActionButtonStyle()
    }
}

struct NaqafinCapsuleButtonStyle: ButtonStyle {

    let isFocused: Bool
    let expandsToAvailableWidth: Bool
    let unfocusedFill: Color
    let unfocusedForeground: Color

    init(
        isFocused: Bool,
        expandsToAvailableWidth: Bool = true,
        unfocusedFill: Color = .white,
        unfocusedForeground: Color = .black
    ) {
        self.isFocused = isFocused
        self.expandsToAvailableWidth = expandsToAvailableWidth
        self.unfocusedFill = unfocusedFill
        self.unfocusedForeground = unfocusedForeground
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                NaqafinCapsuleButtonAppearance(
                    isFocused: isFocused,
                    isPressed: configuration.isPressed,
                    expandsToAvailableWidth: expandsToAvailableWidth,
                    unfocusedFill: unfocusedFill,
                    unfocusedForeground: unfocusedForeground
                )
            )
    }
}

private struct NaqafinCapsuleButtonAppearance: ViewModifier {

    let isFocused: Bool
    let isPressed: Bool
    let expandsToAvailableWidth: Bool
    let unfocusedFill: Color
    let unfocusedForeground: Color

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isFocused ? .black : unfocusedForeground)
            .frame(maxWidth: expandsToAvailableWidth ? .infinity : nil, maxHeight: .infinity)
            .background(isFocused ? Color.white : unfocusedFill, in: Capsule())
            .scaleEffect(isPressed ? 0.96 : isFocused ? 1.04 : 1)
            .shadow(color: isFocused ? .black.opacity(0.5) : .clear, radius: isFocused ? 10 : 0)
            .animation(.easeInOut(duration: 0.1), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
}

struct SupplementActionButtonStyle: ButtonStyle {

    @Environment(\.isFocused)
    private var environmentIsFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                NaqafinCapsuleButtonAppearance(
                    isFocused: environmentIsFocused,
                    isPressed: configuration.isPressed,
                    expandsToAvailableWidth: true,
                    unfocusedFill: .white,
                    unfocusedForeground: .black
                )
            )
    }
}
#else
extension PrimitiveButtonStyle where Self == SupplementActionButtonStyle {

    static var supplementAction: SupplementActionButtonStyle {
        SupplementActionButtonStyle()
    }
}

struct SupplementActionButtonStyle: PrimitiveButtonStyle {

    private func baseLabel(_ configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legacyButton(_ configuration: Configuration) -> some View {
        Button {
            configuration.trigger()
        } label: {
            baseLabel(configuration)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.card)
    }

    @available(iOS 26.0, tvOS 26.0, *)
    private func glassButton(_ configuration: Configuration) -> some View {
        Button {
            configuration.trigger()
        } label: {
            baseLabel(configuration)
                .glassEffect(
                    .regular
                        .tint(.white)
                        .interactive(),
                    in: Capsule()
                )
        }
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        glassButton(configuration)
        #else
        if #available(iOS 26.0, *) {
            glassButton(configuration)
        } else {
            legacyButton(configuration)
        }
        #endif
    }
}
#endif

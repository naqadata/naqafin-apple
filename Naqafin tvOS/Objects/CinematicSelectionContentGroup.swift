//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import JellyfinAPI
import SwiftUI

struct CinematicSelectionContentGroup: ContentGroup {

    let id = "cinematic-selection"
    let viewModel: CinematicSelectionContentGroupViewModel

    var _shouldBeResolved: Bool {
        viewModel.hasResumeItems
    }

    init(
        resumeLibrary: NaqafinResumeItemsLibrary,
        recentlyAddedLibrary: RecentlyAddedLibrary
    ) {
        self.viewModel = CinematicSelectionContentGroupViewModel(
            resumeLibrary: resumeLibrary,
            recentlyAddedLibrary: recentlyAddedLibrary
        )
    }

    func body(with viewModel: CinematicSelectionContentGroupViewModel) -> some View {
        SelectionView(viewModel: viewModel)
    }

    private struct SelectionView: View {

        @ObservedObject
        var viewModel: CinematicSelectionContentGroupViewModel

        @Router
        private var router

        var body: some View {
            let items = viewModel.resumeViewModel.elements.elements

            CinematicItemSelector(
                items: items
            ) { item in
                router.route(to: .item(item: item))
            } topContent: { item in
                Text(item.displayTitle)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .edgePadding(.leading)
            }
            .preference(
                key: ContentGroupCustomizationKey.self,
                value: .ignoreSafeAreaTop
            )
        }
    }
}

struct CinematicRecentlyAddedContentGroup: ContentGroup {

    let id = "cinematic-recently-added"
    let viewModel: CinematicSelectionContentGroupViewModel

    var _shouldBeResolved: Bool {
        viewModel.hasResumeItems && viewModel.recentlyAddedViewModel.elements.isNotEmpty
    }

    func body(with viewModel: CinematicSelectionContentGroupViewModel) -> some View {
        PosterHStackLibrarySection(
            viewModel: viewModel.recentlyAddedViewModel,
            group: viewModel.recentlyAddedGroup
        )
    }
}

final class CinematicSelectionContentGroupViewModel: ViewModel, WithRefresh {

    typealias Background = CinematicSelectionContentGroupViewModel

    let recentlyAddedGroup: PosterGroup<RecentlyAddedLibrary>
    let resumeViewModel: PagingLibraryViewModel<NaqafinResumeItemsLibrary>

    var recentlyAddedViewModel: PagingLibraryViewModel<RecentlyAddedLibrary> {
        recentlyAddedGroup.viewModel
    }

    var background: CinematicSelectionContentGroupViewModel {
        get { self }
        set {}
    }

    var hasResumeItems: Bool {
        resumeViewModel.elements.isNotEmpty
    }

    var hasContent: Bool {
        hasResumeItems || recentlyAddedViewModel.elements.isNotEmpty
    }

    init(
        resumeLibrary: NaqafinResumeItemsLibrary,
        recentlyAddedLibrary: RecentlyAddedLibrary
    ) {
        self.resumeViewModel = PagingLibraryViewModel(library: resumeLibrary, pageSize: 20)
        self.recentlyAddedGroup = PosterGroup(library: recentlyAddedLibrary)

        super.init()

        resumeViewModel.objectWillChange
            .merge(with: recentlyAddedViewModel.objectWillChange)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        Task {
            await refresh()
        }
    }

    func refresh() async {
        async let resume: Void = resumeViewModel.refresh()
        async let recentlyAdded: Void = recentlyAddedViewModel.refresh()

        _ = await (resume, recentlyAdded)
    }
}

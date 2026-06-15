import SwiftUI

extension View {
    /// Shared tab-root header: the large title rendered inline at the
    /// bar's leading edge, so the trailing circular glass actions sit at
    /// the same height across every tab.
    func tabHeaderTitle(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
    }
}

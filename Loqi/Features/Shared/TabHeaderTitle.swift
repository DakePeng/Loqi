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

/// The app's selector-sheet chrome: a bottom sheet of labeled Form rows
/// (each Picker shows its name + current value) with a footer under each
/// section explaining what the choice drives. Shared by the Languages,
/// Summary options, and Recording options sheets — Pickers embedded in
/// context Menus rendered as an unlabeled run of checkmarked options,
/// which is exactly what this replaces. Sections stay bespoke per caller.
struct SelectorSheet<Content: View>: View {
    let title: LocalizedStringKey
    /// Grays the rows (NOT the toolbar) while a job could race the selection.
    var locked: Bool = false
    /// Staged sheets: a bold top-right action (e.g. Apply) with Cancel on
    /// the leading edge. Live-apply sheets omit it and get a plain Done.
    var primaryActionTitle: LocalizedStringKey? = nil
    var primaryActionDisabled: Bool = false
    var primaryAction: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                // Order is load-bearing: .disabled wraps only the Form so
                // the toolbar buttons never lock.
                .disabled(locked)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if let primaryActionTitle, let primaryAction {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(primaryActionTitle, action: primaryAction)
                                .disabled(primaryActionDisabled)
                        }
                    } else {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

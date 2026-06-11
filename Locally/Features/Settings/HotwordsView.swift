import SwiftUI

/// Editor for names and domain terms the pipeline should always get right.
struct HotwordsView: View {
    @Bindable var store: HotwordStore
    @State private var editing: Hotword?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                ForEach(store.hotwords) { hotword in
                    Button {
                        editing = hotword
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hotword.term)
                                .foregroundStyle(.primary)
                            if !renderingsSummary(hotword).isEmpty {
                                Text(renderingsSummary(hotword))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { store.remove(at: $0) }
            } footer: {
                Text("Names and special terms get recognized more reliably, corrected when misheard, and translated consistently.")
            }
        }
        .navigationTitle("Hotwords")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) {
            HotwordEditor(hotword: Hotword(term: "")) { store.add($0) }
        }
        .sheet(item: $editing) { hotword in
            HotwordEditor(hotword: hotword) { store.update($0) }
        }
        .overlay {
            if store.hotwords.isEmpty {
                ContentUnavailableView(
                    "No hotwords yet",
                    systemImage: "character.magnify",
                    description: Text("Add names or jargon the app should always get right."))
            }
        }
    }

    private func renderingsSummary(_ hotword: Hotword) -> String {
        AppLanguage.allCases
            .compactMap { hotword.renderings[$0] }
            .filter { !$0.isEmpty && $0 != hotword.term }
            .joined(separator: " · ")
    }
}

private struct HotwordEditor: View {
    @State var hotword: Hotword
    let onSave: (Hotword) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Term") {
                    TextField("Name or term", text: $hotword.term)
                }
                Section {
                    ForEach(AppLanguage.allCases) { language in
                        TextField(
                            language.displayName,
                            text: renderingBinding(language))
                    }
                } header: {
                    Text("Preferred form per language")
                } footer: {
                    Text("Leave blank to use the term as-is.")
                }
                Section("Note for the translator (optional)") {
                    TextField("e.g. person name, product, keep untranslated", text: $hotword.note)
                }
            }
            .navigationTitle(hotword.term.isEmpty ? "New Hotword" : hotword.term)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(hotword)
                        dismiss()
                    }
                    .disabled(hotword.term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func renderingBinding(_ language: AppLanguage) -> Binding<String> {
        Binding(
            get: { hotword.renderings[language] ?? "" },
            set: { hotword.renderings[language] = $0.isEmpty ? nil : $0 })
    }
}

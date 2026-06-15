import SwiftUI

/// The Vocabulary tab: names and domain terms the pipeline should always
/// get right, plus the inbox of suggestions mined from summary edits.
struct VocabularyView: View {
    @Bindable var store: HotwordStore
    @State private var editing: Hotword?
    @State private var isAdding = false

    private var pendingGroups: [(sessionID: UUID?, title: String, items: [PendingHotword])] {
        var order: [UUID?] = []
        var groups: [UUID?: [PendingHotword]] = [:]
        for item in store.pending {
            let key = item.sessionID
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.map { key in
            let items = groups[key]!
            let title = items.first?.sessionTitle ?? String(localized: "Other suggestions")
            return (key, title, items)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(pendingGroups, id: \.sessionID) { group in
                    pendingGroupSection(group)
                }
                hotwordsSection
            }
            .tabHeaderTitle("Vocabulary")
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
                if store.hotwords.isEmpty, store.pending.isEmpty {
                    ContentUnavailableView(
                        "No hotwords yet",
                        systemImage: "character.magnify",
                        description: Text("Add names or jargon the app should always get right."))
                }
            }
        }
    }

    private func pendingGroupSection(
        _ group: (sessionID: UUID?, title: String, items: [PendingHotword])
    ) -> some View {
        Section {
            ForEach(group.items) { suggestion in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.term)
                        if !suggestion.note.isEmpty {
                            Text(suggestion.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Add") { store.accept(suggestion) }
                        .buttonStyle(.bordered)
                    Button("Dismiss", systemImage: "xmark") {
                        store.dismiss(suggestion)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
        } header: {
            HStack {
                Text(group.title)
                Spacer()
                if group.items.count > 1 {
                    Button("Ignore All") {
                        store.dismissAll(sessionID: group.sessionID)
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    private var hotwordsSection: some View {
        Section {
            ForEach(store.hotwords) { hotword in
                Button {
                    editing = hotword
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hotword.term)
                            .foregroundStyle(.primary)
                        if !formsSummary(hotword).isEmpty {
                            Text(formsSummary(hotword))
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

    /// Caption line: non-default renderings plus aliases.
    private func formsSummary(_ hotword: Hotword) -> String {
        let renderings = AppLanguage.allCases
            .compactMap { hotword.renderings[$0] }
            .filter { !$0.isEmpty && $0 != hotword.term }
        let aliases = (hotword.aliases ?? []).filter { !$0.isEmpty }
        return (renderings + aliases).joined(separator: " · ")
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
                Section {
                    ForEach((hotword.aliases ?? []).indices, id: \.self) { index in
                        TextField("Nickname or short form", text: aliasBinding(index))
                    }
                    .onDelete { hotword.aliases?.remove(atOffsets: $0) }
                    Button("Add alias", systemImage: "plus") {
                        hotword.aliases = (hotword.aliases ?? []) + [""]
                    }
                } header: {
                    Text("Aliases")
                } footer: {
                    Text("Other ways this is said, like a nickname. A misheard alias is corrected to the alias itself, not the term.")
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
                        var cleaned = hotword
                        cleaned.aliases = normalizedAliases()
                        onSave(cleaned)
                        dismiss()
                    }
                    .disabled(hotword.term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Trim, drop empties, dedupe; nil keeps the JSON key absent so files
    /// stay readable by pre-alias app versions.
    private func normalizedAliases() -> [String]? {
        var seen = Set<String>()
        let cleaned = (hotword.aliases ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return cleaned.isEmpty ? nil : cleaned
    }

    private func renderingBinding(_ language: AppLanguage) -> Binding<String> {
        Binding(
            get: { hotword.renderings[language] ?? "" },
            set: { hotword.renderings[language] = $0.isEmpty ? nil : $0 })
    }

    /// Bounds-checked: List can query rows briefly after a deletion.
    private func aliasBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let aliases = hotword.aliases, index < aliases.count else { return "" }
                return aliases[index]
            },
            set: { newValue in
                guard var aliases = hotword.aliases, index < aliases.count else { return }
                aliases[index] = newValue
                hotword.aliases = aliases
            })
    }
}

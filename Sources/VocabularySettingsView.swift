import SwiftUI

// MARK: - Vocabulary Settings

struct VocabularySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newTermInput = ""
    @State private var bulkInput = ""
    @State private var showsBulkEditor = false
    @FocusState private var bulkInputFocused: Bool

    private var terms: [String] {
        VocabularyList.terms(from: appState.customVocabulary)
    }

    private var trimmedNewTerm: String {
        newTermInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Vocabulary", icon: "text.book.closed.fill") {
                    wordsSection
                }
                SettingsCard("Edit as Text", icon: "text.alignleft") {
                    bulkEditSection
                }
            }
            .padding(24)
        }
        .onAppear {
            bulkInput = VocabularyList.serialized(terms)
        }
        .onChange(of: appState.customVocabulary) { _ in
            if !bulkInputFocused {
                bulkInput = VocabularyList.serialized(terms)
            }
        }
        .onDisappear {
            commitBulkInput()
        }
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names, brands, handles, and jargon you use. When something you say sounds like one of these, \(AppName.displayName) writes it exactly as listed. For example, add \"Groq\" and \"grok\" comes out as Groq.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Add a word or phrase", text: $newTermInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(trimmedNewTerm.isEmpty)
            }

            if terms.isEmpty {
                Text("No words yet. Add the ones that keep getting misspelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        VocabularyChip(term: term) {
                            appState.customVocabulary = VocabularyList.removing(term, from: appState.customVocabulary)
                        }
                    }
                }

                Text("\(terms.count) \(terms.count == 1 ? "word" : "words")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bulkEditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Paste or edit many at once", isExpanded: $showsBulkEditor) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $bulkInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 240)
                        .focused($bulkInputFocused)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .onChange(of: bulkInputFocused) { focused in
                            if !focused { commitBulkInput() }
                        }

                    Text("One entry per line. Commas and semicolons also separate entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private func addTerm() {
        guard !trimmedNewTerm.isEmpty else { return }
        appState.customVocabulary = VocabularyList.adding(trimmedNewTerm, to: appState.customVocabulary)
        newTermInput = ""
    }

    private func commitBulkInput() {
        let normalized = VocabularyList.serialized(VocabularyList.terms(from: bulkInput))
        if VocabularyList.terms(from: appState.customVocabulary) != VocabularyList.terms(from: normalized) {
            appState.customVocabulary = normalized
        }
    }
}

private struct VocabularyChip: View {
    let term: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .font(.callout)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(term)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }
}

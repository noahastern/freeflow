import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App Styles Settings

struct AppStylesSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showsAdvanced = false

    private var isEnabled: Bool { appState.appStyleSettings.isEnabled }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("App Styles", icon: "square.grid.2x2.fill") {
                    overviewSection
                }

                SettingsCard("Styles", icon: "paintbrush.fill") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(AppStyleCategory.allCases) { category in
                            AppStyleCategoryRow(category: category)
                            if category != AppStyleCategory.allCases.last {
                                Divider().padding(.vertical, 8)
                            }
                        }
                    }
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)

                SettingsCard("Advanced", icon: "slider.horizontal.3") {
                    DisclosureGroup("Move an app to a different style", isExpanded: $showsAdvanced) {
                        AppStyleAssignmentsSection()
                            .padding(.top, 8)
                    }
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
            }
            .padding(24)
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Match my writing style to the app I'm in", isOn: $appState.appStyleSettings.isEnabled)

            Text("\(AppName.displayName) recognizes common apps and adjusts tone and formatting to fit: casual in chat, complete sentences in email, every detail kept in AI prompts. Nothing to set up. Customize a style below if you want.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.lastContextBundleIdentifier.isEmpty {
                let category = AppStyleResolver.category(
                    bundleIdentifier: appState.lastContextBundleIdentifier,
                    windowTitle: appState.lastContextWindowTitle,
                    assignments: appState.appStyleSettings.appAssignments
                )
                HStack(spacing: 6) {
                    Image(systemName: category.icon)
                        .foregroundStyle(.secondary)
                    Text("Last dictation: \(appState.lastContextAppName.isEmpty ? appState.lastContextBundleIdentifier : appState.lastContextAppName) used \(category.title)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Category Row

private struct AppStyleCategoryRow: View {
    @EnvironmentObject var appState: AppState
    let category: AppStyleCategory

    @State private var isExpanded = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var isCustomized: Bool {
        appState.appStyleSettings.isCustomized(category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: category.icon)
                    .frame(width: 20)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(category.title)
                            .font(.body.weight(.medium))
                        if isCustomized {
                            Text("Customized")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(category.examples)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(isExpanded ? "Done" : "Customize") {
                    if isExpanded { commitDraft() }
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.system(.callout))
                        .frame(minHeight: 70, maxHeight: 140)
                        .focused($draftFocused)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .onChange(of: draftFocused) { focused in
                            if !focused { commitDraft() }
                        }

                    HStack {
                        Text(category == .general
                            ? "Leave empty to use only the main system prompt."
                            : "Added to the system prompt when you dictate into these apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isCustomized {
                            Button("Reset to Default") {
                                appState.appStyleSettings.customInstructions[category.rawValue] = nil
                                draft = category.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
                .padding(.leading, 30)
            }
        }
        .onAppear {
            draft = appState.appStyleSettings.instruction(for: category)
        }
        .onDisappear {
            if isExpanded { commitDraft() }
        }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultInstruction = category.defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: String? = trimmed == defaultInstruction || trimmed.isEmpty ? nil : trimmed
        if appState.appStyleSettings.customInstructions[category.rawValue] != stored {
            appState.appStyleSettings.customInstructions[category.rawValue] = stored
        }
        if trimmed.isEmpty {
            draft = defaultInstruction
        }
    }
}

// MARK: - App Assignments

private struct AppStyleAssignmentsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var runningApps: [(name: String, bundleIdentifier: String)] = []

    private var assignments: [(bundleIdentifier: String, assignment: AppStyleAssignment)] {
        appState.appStyleSettings.appAssignments
            .map { ($0.key, $0.value) }
            .sorted { $0.assignment.appName.localizedCaseInsensitiveCompare($1.assignment.appName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps are grouped automatically. If one lands in the wrong group, add it here and pick the style it should use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(assignments, id: \.bundleIdentifier) { entry in
                HStack(spacing: 8) {
                    Text(entry.assignment.appName)
                        .lineLimit(1)
                    Spacer()
                    Picker(entry.assignment.appName, selection: categoryBinding(for: entry.bundleIdentifier)) {
                        ForEach(AppStyleCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)

                    Button {
                        appState.appStyleSettings.appAssignments[entry.bundleIdentifier] = nil
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Use the automatic style for \(entry.assignment.appName)")
                }
            }

            Menu("Add App") {
                ForEach(runningApps.filter { appState.appStyleSettings.appAssignments[$0.bundleIdentifier] == nil }, id: \.bundleIdentifier) { app in
                    Button(app.name) {
                        assign(name: app.name, bundleIdentifier: app.bundleIdentifier)
                    }
                }
                if !runningApps.isEmpty {
                    Divider()
                }
                Button("Choose Application…") {
                    chooseApplication()
                }
            }
            .fixedSize()
        }
        .onAppear(perform: refreshRunningApps)
    }

    private func categoryBinding(for bundleIdentifier: String) -> Binding<AppStyleCategory> {
        Binding(
            get: { appState.appStyleSettings.appAssignments[bundleIdentifier]?.category ?? .general },
            set: { appState.appStyleSettings.appAssignments[bundleIdentifier]?.category = $0 }
        )
    }

    private func assign(name: String, bundleIdentifier: String) {
        let current = AppStyleResolver.defaultCategory(bundleIdentifier: bundleIdentifier, windowTitle: nil) ?? .general
        appState.appStyleSettings.appAssignments[bundleIdentifier] = AppStyleAssignment(appName: name, category: current)
    }

    private func refreshRunningApps() {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleIdentifier: String)? in
                guard let bundleIdentifier = app.bundleIdentifier,
                      bundleIdentifier != ownBundleIdentifier,
                      seen.insert(bundleIdentifier).inserted else { return nil }
                return (app.localizedName ?? bundleIdentifier, bundleIdentifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "Choose an app to assign a style to"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        assign(name: name, bundleIdentifier: bundleIdentifier)
    }
}

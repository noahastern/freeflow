import Foundation

/// A saved sound choice is either a named macOS sound (e.g. "Tink") or an
/// absolute path to an audio file the user picked.
enum AlertSoundSlot: String, CaseIterable {
    case start
    case stop

    var storageKey: String { "\(rawValue)_sound" }

    var defaultChoice: String {
        switch self {
        case .start: return "Tink"
        case .stop: return "Pop"
        }
    }

    var title: String {
        switch self {
        case .start: return "Start sound"
        case .stop: return "Stop sound"
        }
    }

    func load(from defaults: UserDefaults) -> String {
        guard let saved = defaults.string(forKey: storageKey),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultChoice
        }
        return saved
    }
}

enum AlertSoundLibrary {
    static let audioFileExtensions: Set<String> = ["aiff", "aif", "aifc", "wav", "caf", "mp3", "m4a"]

    /// Same folders NSSound(named:) searches, user folder first.
    static var standardSoundDirectories: [URL] {
        let fileManager = FileManager.default
        let user = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
            .map { $0.appendingPathComponent("Sounds", isDirectory: true) }
        return user + [
            URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
        ]
    }

    static func isFilePath(_ choice: String) -> Bool {
        choice.hasPrefix("/")
    }

    static func displayName(for choice: String) -> String {
        guard isFilePath(choice) else { return choice }
        return URL(fileURLWithPath: choice).deletingPathExtension().lastPathComponent
    }

    /// Sorted, de-duplicated sound names that NSSound(named:) can resolve.
    static func soundNames(
        in directories: [URL] = standardSoundDirectories,
        fileManager: FileManager = .default
    ) -> [String] {
        var names = Set<String>()
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in contents where audioFileExtensions.contains(file.pathExtension.lowercased()) {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

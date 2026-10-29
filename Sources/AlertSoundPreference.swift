import Foundation

/// A saved sound choice is a sound bundled with the app (e.g. "freeflow-start"),
/// a named macOS sound (e.g. "Tink"), or an absolute path to an audio file the
/// user picked. NSSound(named:) resolves bundled and macOS sounds alike.
enum AlertSoundSlot: String, CaseIterable {
    case start
    case stop

    var storageKey: String { "\(rawValue)_sound" }

    var defaultChoice: String {
        switch self {
        case .start: return AlertSoundLibrary.bundledStartSound
        case .stop: return AlertSoundLibrary.bundledStopSound
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
    static let bundledStartSound = "freeflow-start"
    static let bundledStopSound = "freeflow-stop"

    /// Sounds shipped in the app's Resources folder, listed ahead of macOS sounds.
    static let bundledSounds: [(name: String, title: String)] = [
        (bundledStartSound, "FreeFlow Start"),
        (bundledStopSound, "FreeFlow Stop"),
    ]

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
        if let bundled = bundledSounds.first(where: { $0.name == choice }) {
            return bundled.title
        }
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

    /// Bundled sounds first, then everything NSSound(named:) finds on the system.
    static func pickerSoundNames(
        in directories: [URL] = standardSoundDirectories,
        fileManager: FileManager = .default
    ) -> [String] {
        let bundledNames = bundledSounds.map(\.name)
        let systemNames = soundNames(in: directories, fileManager: fileManager)
            .filter { !bundledNames.contains($0) }
        return bundledNames + systemNames
    }
}

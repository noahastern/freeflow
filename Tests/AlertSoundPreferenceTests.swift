import Foundation

enum AlertSoundPreferenceTests {
    static func run() {
        let suite = "FreeFlowTests.AlertSound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(AlertSoundSlot.start.load(from: defaults), "Tink")
        TestSupport.expectEqual(AlertSoundSlot.stop.load(from: defaults), "Pop")
        TestSupport.expect(defaults.object(forKey: AlertSoundSlot.start.storageKey) == nil, "Loading the default must not persist a choice")

        defaults.set("Glass", forKey: AlertSoundSlot.start.storageKey)
        defaults.set("/tmp/Example Sound.wav", forKey: AlertSoundSlot.stop.storageKey)
        TestSupport.expectEqual(AlertSoundSlot.start.load(from: defaults), "Glass")
        TestSupport.expectEqual(AlertSoundSlot.stop.load(from: defaults), "/tmp/Example Sound.wav")

        defaults.set("  ", forKey: AlertSoundSlot.start.storageKey)
        TestSupport.expectEqual(AlertSoundSlot.start.load(from: defaults), "Tink")

        TestSupport.expect(AlertSoundLibrary.isFilePath("/tmp/a.wav"), "Absolute paths are files")
        TestSupport.expect(!AlertSoundLibrary.isFilePath("Pop"), "Bare names are named sounds")
        TestSupport.expectEqual(AlertSoundLibrary.displayName(for: "/tmp/Example Sound.wav"), "Example Sound")
        TestSupport.expectEqual(AlertSoundLibrary.displayName(for: "Pop"), "Pop")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("FreeFlowTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try! fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try! fileManager.createDirectory(at: second, withIntermediateDirectories: true)
        for path in [first.appendingPathComponent("beta.aiff"),
                     first.appendingPathComponent("notes.txt"),
                     second.appendingPathComponent("Alpha.WAV"),
                     second.appendingPathComponent("beta.wav")] {
            fileManager.createFile(atPath: path.path, contents: Data())
        }
        let missing = root.appendingPathComponent("missing")
        TestSupport.expectEqual(
            AlertSoundLibrary.soundNames(in: [first, second, missing], fileManager: fileManager),
            ["Alpha", "beta"]
        )
    }
}

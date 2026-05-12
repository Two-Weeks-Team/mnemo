// Invariant #5: the on-device store lives OUTSIDE all backup / sync / Spotlight
// scopes. This is the engine-side enforcement: directory-level + file-level
// attributes. The *location* (a sandbox container that is not the iCloud /
// Handoff container, not Documents) is the app layer's job (Phase 4/5); this
// hardens whatever path it's handed. A CI test asserts these attributes
// (PathHardeningTests).
//
// At-rest encryption: on iOS this sets `FileProtectionType.completeUnlessOpen`
// (overridable). On macOS the file-protection attribute is not supported by the
// filesystem API, so the at-rest story there is FileVault + (Phase 5) an
// app-managed key in the Keychain — documented, not silently skipped.

import Foundation

public enum StorageHardening {
    /// Marker filename that tells Spotlight to never index a directory's contents.
    public static let spotlightExclusionMarker = ".metadata_never_index"

    /// Harden a directory that will hold the Mnemo store:
    /// - create it if missing,
    /// - set `isExcludedFromBackup = true` (Time Machine / iCloud backup skip it),
    /// - drop a `.metadata_never_index` marker (Spotlight skips its contents).
    /// Idempotent.
    public static func hardenDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try setExcludedFromBackup(url)
        let marker = url.appendingPathComponent(spotlightExclusionMarker)
        if !fm.fileExists(atPath: marker.path) {
            try Data().write(to: marker)
        }
    }

    /// Harden a single file (the db, its WAL/SHM sidecars): exclude from backup,
    /// and on iOS apply file protection.
    public static func hardenFile(
        _ url: URL,
        iosProtection: FileProtectionType = .completeUnlessOpen
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try setExcludedFromBackup(url)
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: iosProtection], ofItemAtPath: url.path
        )
        #endif
    }

    /// Whether a URL currently carries `isExcludedFromBackup`. Used by the CI test.
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    /// Whether a directory carries the Spotlight-exclusion marker.
    public static func hasSpotlightExclusionMarker(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(spotlightExclusionMarker).path
        )
    }

    private static func setExcludedFromBackup(_ url: URL) throws {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
    }
}

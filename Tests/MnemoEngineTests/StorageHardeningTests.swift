import Testing
import Foundation
@testable import MnemoEngine

@Suite("StorageHardening — the store lives outside backup / sync / Spotlight")
struct StorageHardeningTests {

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemo-test-\(UUID().uuidString)")
        return url
    }

    @Test("hardenDirectory: excluded from backup + carries the Spotlight-exclusion marker")
    func directoryHardened() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try StorageHardening.hardenDirectory(dir)

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(StorageHardening.isExcludedFromBackup(dir))
        #expect(StorageHardening.hasSpotlightExclusionMarker(dir))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".metadata_never_index").path))
    }

    @Test("hardenDirectory is idempotent")
    func idempotent() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try StorageHardening.hardenDirectory(dir)
        try StorageHardening.hardenDirectory(dir)   // again — must not throw
        #expect(StorageHardening.isExcludedFromBackup(dir))
        #expect(StorageHardening.hasSpotlightExclusionMarker(dir))
    }

    @Test("Opening a SQLiteMemoryStore hardens the directory and the db file")
    func storeHardensItsPaths() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteMemoryStore(directory: dir)
        _ = await store.count   // touch it

        #expect(StorageHardening.isExcludedFromBackup(dir))
        #expect(StorageHardening.hasSpotlightExclusionMarker(dir))
        let dbURL = dir.appendingPathComponent("mnemo.sqlite3")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(StorageHardening.isExcludedFromBackup(dbURL))
    }
}

import Foundation
import Testing
@testable import SRCore

@Suite struct CachePrivacyTests {
    @Test func repairsExistingDirectoryAndProtectsNewAudio() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("sr-private-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let cache = AudioCache(directory: directory)
        #expect((try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700)
        cache.store("audio", data: Data([1, 2, 3]))
        _ = cache.maintenancePassCount // drain the asynchronous disk write
        let audio = directory.appendingPathComponent("audio.mp3")
        #expect((try fm.attributesOfItem(atPath: audio.path)[.posixPermissions] as? Int) == 0o600)
        #expect(cache.lookup("audio") == Data([1, 2, 3]))
    }

    @Test func unavailablePrivateDirectoryDisablesCaching() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("sr-cache-file-\(UUID())")
        defer { try? fm.removeItem(at: file) }
        try Data([1]).write(to: file)
        let cache = AudioCache(directory: file.appendingPathComponent("cache"))
        #expect(!cache.enabled)
        cache.enabled = true
        #expect(!cache.enabled)
        cache.store("audio", data: Data([2]))
        #expect(cache.lookup("audio") == nil)
    }
}

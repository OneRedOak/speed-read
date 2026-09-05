import Foundation
import Darwin
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

    @Test func removesInheritedReadACLsBeforeCaching() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("sr-acl-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit", directory.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(try hasACLEntries(directory))
        let cache = AudioCache(directory: directory)
        #expect(cache.enabled)
        #expect(try !hasACLEntries(directory))
        cache.store("audio", data: Data([1, 2]))
        _ = cache.maintenancePassCount
        #expect(try !hasACLEntries(directory.appendingPathComponent("audio.mp3")))
    }

    private func hasACLEntries(_ url: URL) throws -> Bool {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            // macOS reports an absent extended ACL as ENOENT even when the
            // file exists. Do not confuse that with a missing audio file.
            let code = errno
            if code == ENOENT, FileManager.default.fileExists(atPath: url.path) { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
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

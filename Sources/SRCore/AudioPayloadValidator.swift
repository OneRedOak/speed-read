import Foundation

public enum AudioPayloadValidator {
    public static func isMP3(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let bytes = [UInt8](data.prefix(3))
        if bytes == [0x49, 0x44, 0x33] { return true } // ID3
        return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
    }

    public static func isWAV(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.prefix(4) == Data("RIFF".utf8)
            && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
    }
}

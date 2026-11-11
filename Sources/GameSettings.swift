import Compression
import CryptoKit
import Foundation

struct GameSettings {
    let game: URL
    let storage: URL

    // The Steam System file is length-prefixed raw LZ4. In the verified layout,
    // the five locale bytes follow a fixed header. Reject unknown layouts.
    private static let localeRange = 60..<65
    private static let layoutDigest = "9e7d09d558d4fee55b97e8905013df13223c9a6a680a1fa625560f28b78a22e8"
    private static let localeMask: [UInt8] = [0xc5, 0x25, 0xa4, 0x05, 0xa2]

    func syncLanguage(from source: String, to target: String, checkGameClosed: () throws -> Void) throws {
        guard source != target else { return }
        let main = try systemFile(source)
        let secondary = try systemFile(target)
        let sourceData = try Self.unpack(Data(contentsOf: main))
        let original = try Data(contentsOf: secondary)
        let targetData = try Self.unpack(original)
        guard try Self.locale(in: sourceData) != Self.locale(in: targetData) else { return }
        var updated = targetData
        updated.replaceSubrange(Self.localeRange, with: sourceData[Self.localeRange])
        let encoded = try Self.pack(updated)
        guard try Self.unpack(encoded) == updated else { throw Self.unsupported }
        try checkGameClosed()
        guard try Data(contentsOf: secondary) == original else {
            throw SwitchError("游戏刚刚更新了语言设置，请在退出游戏后重试。")
        }
        let backup = storage.appendingPathComponent("game-language-\(target).backup")
        try original.write(to: backup, options: .atomic)
        try encoded.write(to: secondary, options: .atomic)
    }

    private func systemFile(_ folder: String) throws -> URL {
        guard (1...16).contains(folder.utf8.count), folder.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw Self.unsupported }
        var path = game
        for component in ["LocalSave", folder, "0000", "e2"] {
            path.appendPathComponent(component)
            let props = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard props?.isDirectory == true, props?.isSymbolicLink != true else {
                throw SwitchError("找不到账号的语言设置。首次进入游戏并退出后，可再次切换以同步。")
            }
        }
        let file = path.appendingPathComponent("e2264531")
        let props = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard props?.isRegularFile == true, props?.isSymbolicLink != true,
              let size = props?.fileSize, (5...65_536).contains(size) else { throw Self.unsupported }
        return file
    }

    static func locale(in raw: Data) throws -> String {
        guard raw.count >= localeRange.upperBound,
              SHA256.hash(data: raw.prefix(localeRange.lowerBound))
                .map({ String(format: "%02x", $0) }).joined() == layoutDigest else {
            throw unsupported
        }
        let bytes = zip(raw[localeRange], localeMask).map { $0 ^ $1 }
        let locale = String(decoding: bytes, as: UTF8.self)
        guard locale.range(of: #"^[a-z]{2}-[A-Z]{2}$"#, options: .regularExpression) != nil else {
            throw unsupported
        }
        return locale
    }

    static func unpack(_ data: Data) throws -> Data {
        guard data.count > 4 else { throw unsupported }
        let size = data.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard (localeRange.upperBound...65_536).contains(size) else { throw unsupported }
        let compressed = Array(data.dropFirst(4))
        var raw = [UInt8](repeating: 0, count: size)
        let count = compression_decode_buffer(&raw, size, compressed, compressed.count, nil, COMPRESSION_LZ4_RAW)
        guard count == size else { throw unsupported }
        return Data(raw)
    }

    static func pack(_ raw: Data) throws -> Data {
        let size = raw.count
        let capacity = size + size / 255 + 16
        var output = [UInt8](repeating: 0, count: capacity)
        let bytes = Array(raw)
        let count = compression_encode_buffer(&output, capacity, bytes, size, nil, COMPRESSION_LZ4_RAW)
        guard count > 0 else { throw unsupported }
        var length = UInt32(size).littleEndian
        var encoded = withUnsafeBytes(of: &length) { Data($0) }
        encoded.append(contentsOf: output.prefix(count))
        return encoded
    }

    private static var unsupported: SwitchError {
        SwitchError("游戏语言设置格式未识别，已保留该账号当前设置。")
    }
}

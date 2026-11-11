import Foundation

enum RoyalFinish {
    private static let cardLimit = 65_536

    static func supports(_ cardID: Int) -> Bool { (1..<cardLimit).contains(cardID) }

    static func selectionFile(_ ids: Set<Int>) throws -> Data {
        guard !ids.isEmpty, ids.allSatisfy(supports) else {
            throw SwitchError("动态镜碎选项包含无效的卡片编号。")
        }
        var bytes = [UInt8](repeating: 0, count: cardLimit / 8)
        for id in ids { bytes[id / 8] |= 1 << (id % 8) }
        return Data(bytes)
    }
}

import Foundation

struct SummonAnimation: Hashable, Identifiable {
    let cid: Int
    let artworkID: Int
    let name: String
    let donor: Int?

    static let catalogPath = "70/70e201b4"
    static let gatePath = "60/60c98f0d"
    static let kagari = Self(cid: 13668, artworkID: 63288574, name: "闪刀姬－篝", donor: 3899)
    static let shizuku = Self(cid: 13669, artworkID: 90673289, name: "闪刀姬－雫", donor: 3433)
    static let all: [Self] = [
        kagari, shizuku,
        .init(cid: 4041, artworkID: 46986419, name: "黑魔导", donor: 3863),
        .init(cid: 4041, artworkID: 46986421, name: "黑魔导", donor: 3880),
        .init(cid: 4007, artworkID: 89631139, name: "青眼白龙", donor: 3801),
        .init(cid: 7734, artworkID: 44508095, name: "星尘龙", donor: 3882),
        .init(cid: 13082, artworkID: 5043011, name: "防火墙龙", donor: nil),
        .init(cid: 11313, artworkID: 58481573, name: "假面－英雄 暗法", donor: nil),
        .init(cid: 4998, artworkID: 10000002, name: "欧贝利斯克之巨神兵", donor: 3868),
        .init(cid: 5000, artworkID: 10000012, name: "拉之翼神龙", donor: 3401),
        .init(cid: 4999, artworkID: 10000022, name: "欧西里斯之天空龙", donor: 3869),
        .init(cid: 11258, artworkID: 20366275, name: "神影依・拿非利", donor: 3894),
        .init(cid: 19188, artworkID: 29301451, name: "S：P小夜骑士", donor: 22747),
        .init(cid: 15627, artworkID: 36609519, name: "邪恶★双子 璃拉", donor: 3438),
        .init(cid: 13601, artworkID: 38342336, name: "梦魇曲・独角兽", donor: 3421),
        .init(cid: 14765, artworkID: 41232648, name: "龙女仆・总管龙女", donor: 3435),
        .init(cid: 14496, artworkID: 4280259, name: "召命之神弓－阿波罗萨", donor: 3411),
        .init(cid: 7696, artworkID: 60800382, name: "废品战士", donor: 19077),
        .init(cid: 14676, artworkID: 65741787, name: "I：P百变莱娜", donor: 3415),
        .init(cid: 14676, artworkID: 65741789, name: "I：P百变莱娜", donor: 22746),
        .init(cid: 19148, artworkID: 72270340, name: "黑魔女 迪亚贝尔斯塔", donor: 21231),
        .init(cid: 7898, artworkID: 73580472, name: "黑蔷薇龙", donor: 3420),
        .init(cid: 12849, artworkID: 75286622, name: "召唤兽 梅尔卡巴", donor: 3431),
        .init(cid: 18017, artworkID: 81260680, name: "大日女之御巫", donor: 21733),
        .init(cid: 17785, artworkID: 81497286, name: "迷宫城的白银姬・拉比丽斯", donor: 21230),
        .init(cid: 11721, artworkID: 82044280, name: "清透翼同步龙", donor: 3873),
        .init(cid: 7096, artworkID: 83965311, name: "命运－英雄 血魔-D", donor: 3413),
        .init(cid: 15032, artworkID: 86066373, name: "访问码语者", donor: 21226),
        .init(cid: 15626, artworkID: 9205574, name: "邪恶★双子 姬丝吉尔", donor: 3437),
        .init(cid: 11257, artworkID: 94977270, name: "神影依・米德拉什", donor: 3895),
        .init(cid: 15123, artworkID: 95440947, name: "黄金卿埃尔德里奇", donor: 3423),
    ]
    static var scope: Set<String> { Set(all.flatMap(\.paths) + [catalogPath, gatePath]) }
    var id: Int { artworkID }

    var paths: [String] {
        ["SD", "HighEnd_HD"].map { quality in
            let logical = "Duel/Timeline/Duel/MonsterCutIn/tcg/P\(cid)/\(quality)/P\(cid)"
            var crc = UInt32.max
            for byte in logical.utf8 {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            let hash = String(format: "%08x", ~crc)
            return "\(hash.prefix(2))/\(hash)"
        }
    }

    static func hasSource(artworkID: Int, proDirectory: URL) -> Bool {
        let root = proDirectory.appendingPathComponent("MDPro3_Data/StandaloneWindows64")
        let fm = FileManager.default
        var directory: ObjCBool = false
        if fm.fileExists(atPath: root.appendingPathComponent("MonsterCutin2/\(artworkID)").path,
                         isDirectory: &directory), !directory.boolValue { return true }
        let folder = root.appendingPathComponent("MonsterCutin/\(artworkID)")
        return (try? fm.contentsOfDirectory(atPath: folder.path).contains {
            $0.utf8.count == 8 && UInt32($0, radix: 16) != nil
        }) == true
    }
}

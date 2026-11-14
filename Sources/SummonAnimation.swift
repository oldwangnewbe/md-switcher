import Foundation

struct SummonAnimation: Codable, Hashable, Identifiable {
    enum ActivationStyle: Int, Codable {
        case standard = 1, with4x3, withOpening, both = 5
    }

    enum Category: String, CaseIterable {
        case replacement = "召唤演出替换"
        case activation = "发动演出替换"
        case addition = "新增召唤演出"

        var description: String {
            switch self {
            case .replacement: "让已有召唤演出的普通版卡片播放异画版演出。"
            case .activation: "让普通版卡片播放异画版的发动演出。"
            case .addition: "为原版没有召唤演出的卡片添加 MDPro3 演出。"
            }
        }
    }

    let cid: Int
    let artworkID: Int
    let name: String
    let donor: Int?
    let activationStyle: ActivationStyle?
    let addsSummon: Bool

    init(cid: Int, artworkID: Int, name: String, donor: Int? = nil,
         activationStyle: ActivationStyle? = nil, addsSummon: Bool = false) {
        self.cid = cid
        self.artworkID = artworkID
        self.name = name
        self.donor = donor
        self.activationStyle = activationStyle
        self.addsSummon = addsSummon
    }

    var category: Category {
        if addsSummon { return .addition }
        return activationStyle == nil ? .replacement : .activation
    }

    var packKind: Int { addsSummon ? 4 : activationStyle?.rawValue ?? 0 }
    var sourceAvailableWithoutMDPro3: Bool { donor != nil }

    struct Slot: Hashable {
        let cid: Int
        let activation: Bool
    }

    var slot: Slot { Slot(cid: cid, activation: activationStyle != nil) }

    static let catalogPath = "70/70e201b4"
    static let gatePath = "60/60c98f0d"
    static let kagari = Self(cid: 13668, artworkID: 63288574, name: "闪刀姬－篝", donor: 3899)
    static let shizuku = Self(cid: 13669, artworkID: 90673289, name: "闪刀姬－雫", donor: 3433)
    // Used only to read journals from before the local catalog stored full selections.
    static let legacyOptions: [Self] = [
        .init(cid: 5328, artworkID: 32807848, name: "增援", donor: 20040, activationStyle: .with4x3),
        .init(cid: 13619, artworkID: 24224831, name: "墓穴指名者", donor: 21233, activationStyle: .withOpening),
        .init(cid: 13671, artworkID: 63166096, name: "闪刀起动－交闪", donor: 3434, activationStyle: .standard),
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
        .init(cid: 13670, artworkID: 26077389, name: "闪刀姬－零衣", addsSummon: true),
        .init(cid: 4766, artworkID: 38033121, name: "黑魔导女孩", addsSummon: true),
        .init(cid: 6653, artworkID: 89943723, name: "元素－英雄 新宇侠", addsSummon: true),
        .init(cid: 12321, artworkID: 50954680, name: "水晶翼同步龙", addsSummon: true),
        .init(cid: 12639, artworkID: 1621413, name: "暗镇魂超量龙", addsSummon: true),
        .init(cid: 14203, artworkID: 73639099, name: "露珠之虫惑魔", addsSummon: true),
        .init(cid: 14759, artworkID: 13171876, name: "龙女仆・清扫龙女", addsSummon: true),
        .init(cid: 16493, artworkID: 55273560, name: "白之圣女 艾克利西亚", addsSummon: true),
    ]
    static var scope: Set<String> { Set(legacyOptions.flatMap(\.paths) + [catalogPath, gatePath]) }
    var id: String { "\(cid):\(artworkID):\(packKind)" }

    var paths: [String] {
        let names: [String]
        if let activationStyle {
            let token = String(format: "Ef%05d", cid)
            let root = "Duel/Timeline/Card/tcg/\(token)/\(token)"
            switch activationStyle {
            case .standard: names = [root]
            case .with4x3: names = [root, root + "_4x3"]
            case .withOpening: names = [root, root + "Op"]
            case .both: names = [root, root + "_4x3", root + "Op"]
            }
        } else {
            names = ["SD", "HighEnd_HD"].map { "Duel/Timeline/Duel/MonsterCutIn/tcg/P\(cid)/\($0)/P\(cid)" }
        }
        return names.map { logical in
            var crc = UInt32.max
            for byte in logical.utf8 {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
            }
            let hash = String(format: "%08x", ~crc)
            return "\(hash.prefix(2))/\(hash)"
        }
    }

}

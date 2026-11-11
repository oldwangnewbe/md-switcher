import CryptoKit
import Foundation

struct SkyStrikerPack {
    struct Card: Decodable, Identifiable {
        struct SourceArtwork: Decodable, Equatable {
            let format: Int
            let cid: Int
            let sha256: String
        }
        struct OverFrame: Decodable, Equatable {
            let cardID: Int
            let gate: String
        }
        struct Variant: Decodable, Identifiable {
            let id: Int
            let sha256: String
        }
        let name: String
        let path: String
        let originalSHA256: String?
        let variants: [Variant]
        let sourceArtwork: SourceArtwork?
        let overFrame: OverFrame?
        var id: String { path }
    }

    let directory: URL
    let cards: [Card]

    init(directory: URL) throws {
        self.directory = directory
        cards = try JSONDecoder().decode([Card].self, from: Data(
            contentsOf: directory.appendingPathComponent("manifest.json")
        ))
    }

    static var availableDirectory: URL? {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MD Switcher/SkyStriker")
        return [Bundle.main.resourceURL?.appendingPathComponent("SkyStriker"), local]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }

    static func bundled() throws -> SkyStrikerPack {
        guard let directory = availableDirectory else { throw SwitchError("未找到闪刀快捷素材包。") }
        return try SkyStrikerPack(directory: directory)
    }

    func preview(_ id: Int) -> URL { directory.appendingPathComponent("\(id).jpg") }

    func originalPreview(for card: Card) -> URL {
        directory.appendingPathComponent("original-\((card.path as NSString).lastPathComponent).jpg")
    }

    func verifiedBundle(_ variant: Card.Variant, for card: Card) throws -> Data {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(variant.id).bundle"))
        guard (card.path == SummonAnimation.catalogPath || data.starts(with: Data("UnityFS\0".utf8))),
              artworkDigest(data) == variant.sha256 else {
            throw SwitchError("「\(card.name)」的异画资源校验失败。")
        }
        return data
    }
}

struct ArtworkEdit {
    // A zero value requests the original art for that path. Other paths stay out of scope.
    let choices: [String: Int]
    let packs: [SkyStrikerPack]

    var scope: Set<String> { Set(choices.keys) }
    var selections: [String: Int] { choices.filter { $0.value > 0 } }
}

struct SkyStrikerMod {
    struct Result {
        let installed: Int
        let preserved: Int
    }

    private struct Entry: Codable {
        let original: Data?
        var replacements: Set<String>
    }

    private struct OverFrames: Codable {
        let gate: String
        let cards: [String: Int]
    }

    private struct State: Codable {
        var selections: [String: Int] = [:]
        var files: [String: Entry] = [:]
        var pendingSummonAnimation: Bool?
        var summonChoices: Set<Int>?
        var overFrames: OverFrames?
        var pendingOverFramePaths: Set<String>?
    }

    private struct Change {
        let url: URL
        let before: Data?
        let after: Data?
        let maxBytes: Int?
    }

    private let account: URL
    private static let journalLimit = 256 * 1024 * 1024
    private var cache: URL { account.appendingPathComponent("0000") }
    private var journal: URL { account.appendingPathComponent(".md-switcher-sky-striker.json") }

    init(resources: ResourceReuse, account: String) throws {
        guard try resources.accountDirectories().contains(account) else {
            throw SwitchError("请选择资源目录已确认的账号。")
        }
        self.account = resources.root.appendingPathComponent(account)
    }

    func selections() throws -> [String: Int] { try state().selections }

    func requireSummonReady() throws {
        let state = try state()
        if state.pendingOverFramePaths != nil {
            throw SwitchError("有未完成的超框写入。退出游戏后请重新应用或恢复同一组卡图。")
        }
        if state.pendingSummonAnimation == true {
            throw SwitchError("有未完成的召唤动画写入。请在「召唤动画」里恢复原演出后再启动。")
        }
    }

    func backedUpOriginals() throws -> [String: Data] { try state().files.compactMapValues(\.original) }

    func addedSummonFiles() throws -> Set<String> {
        Set(try state().files.filter { $0.value.original == nil }.keys)
    }

    func hasAddedSummonTriggers() throws -> Bool {
        try state().files[SummonAnimation.gatePath] != nil
    }

    func summonSelections() throws -> Set<SummonAnimation> {
        let current = try state()
        if let saved = current.summonChoices {
            return Set(SummonAnimation.all.filter { saved.contains($0.id) })
        }
        return Set([SummonAnimation.kagari, .shizuku].filter { card in
            card.paths.allSatisfy { current.selections[$0] != nil }
        })
    }

    func originalAsset(path: String, size: Int, sha256: String) throws -> Data {
        let url = try assetURL(path)
        if let backup = try state().files[path]?.original, backup.count == size, artworkDigest(backup) == sha256 {
            return backup
        }
        let limit = SummonAnimation.scope.contains(path) ? 24 * 1024 * 1024 : nil
        if let live = try readFile(url, maxBytes: limit), live.count == size, artworkDigest(live) == sha256 {
            return live
        }
        throw SwitchError("原版卡图与游戏索引不匹配，请先确认主账号的游戏资源版本。")
    }

    func update(_ selected: [String: Int], pack: SkyStrikerPack?,
                scope: Set<String>? = nil, additionalPacks: [SkyStrikerPack] = [],
                newSummonPaths: Set<String> = [], summonChoices: Set<Int>? = nil,
                editOverFrameGate: ((Data, Set<Int>) throws -> Data)? = nil,
                checkGameClosed: () throws -> Void) throws -> Result {
        let current = try state()
        let paths = scope ?? Set(current.files.keys).union(selected.keys)
        guard paths.isSuperset(of: selected.keys) else { throw SwitchError("卡图替换范围不匹配。") }
        guard !paths.isEmpty else { return Result(installed: 0, preserved: 0) }
        if let pending = current.pendingOverFramePaths, !paths.isSuperset(of: pending) {
            throw SwitchError("请先重新应用或恢复上一次写入的整组超框卡图。")
        }
        try checkGameClosed()
        var desired = current
        var pending = current
        var changes: [Change] = []
        var preserved = 0
        var overFrameGate = current.overFrames?.gate
        var overFrameCards = current.overFrames?.cards ?? [:]
        var overFrameScope = current.pendingOverFramePaths ?? []
        let packs = pack.map { [$0] + additionalPacks } ?? additionalPacks
        let catalog = SummonAnimation.catalogPath
        let editingSummons = paths.contains(catalog)
        if editingSummons {
            pending.pendingSummonAnimation = true
            desired.pendingSummonAnimation = nil
            desired.summonChoices = summonChoices
        }
        let gate = SummonAnimation.gatePath
        let orderedPaths = paths.subtracting([catalog, gate]).filter { $0 != overFrameGate }.sorted()
        if let overFrameGate, selected[overFrameGate] != nil {
            throw SwitchError("超框登记须随卡图一起更新。")
        }
        // Publish new dependencies after their prefabs. On full restore disable the
        // redirection before putting the original prefabs back.
        let gatePaths = paths.contains(gate) ? [gate] : []
        guard selected[gate] == nil else { throw SwitchError("当前仅支持替换原有的召唤演出。") }
        let pathOrder = if !editingSummons { gatePaths + orderedPaths }
            else if selected[catalog] == nil { gatePaths + [catalog] + orderedPaths }
            else { gatePaths + orderedPaths + [catalog] }
        for path in pathOrder {
            let previous = current.files[path]
            let id = selected[path]
            if overFrameCards.removeValue(forKey: path) != nil { overFrameScope.insert(path) }
            guard previous != nil || id != nil else { continue }
            desired.files[path] = nil
            desired.selections[path] = id
            let canBeAbsent = newSummonPaths.contains(path) || (previous != nil && previous?.original == nil)
            let url = try assetURL(path, allowMissingFolder: canBeAbsent)
            let maxBytes = editingSummons || canBeAbsent ? 24 * 1024 * 1024 : nil
            let before = try readFile(url, maxBytes: maxBytes)
            if before == nil && !canBeAbsent {
                if id == nil { continue }
                throw SwitchError("所选账号缺少卡图资源，请先启动游戏完成资源准备。")
            }
            let beforeHash = before.map(artworkDigest)
            if let previous, let beforeHash, beforeHash != previous.original.map(artworkDigest),
               !previous.replacements.contains(beforeHash) {
                if path == gate {
                    throw SwitchError("召唤触发配置已被游戏或其他 Mod 更新，无法安全移除旧演出。")
                }
                guard id == nil else {
                    throw SwitchError("卡图已被游戏更新或其他 Mod 改动。请先恢复，再检查当前版本。")
                }
                preserved += 1
                continue
            }

            let after: Data?
            if let id {
                let original = previous == nil ? before : previous?.original
                let originalSHA256 = original.map(artworkDigest)
                let matches = packs.lazy.compactMap { candidate -> (SkyStrikerPack, SkyStrikerPack.Card, SkyStrikerPack.Card.Variant)? in
                    guard let card = candidate.cards.first(where: { $0.path == path }),
                          let variant = card.variants.first(where: { $0.id == id }) else { return nil }
                    return (candidate, card, variant)
                }
                guard let first = matches.first else {
                    throw SwitchError("找不到所选异画。")
                }
                guard let (pack, card, variant) = matches.first(where: { $0.1.originalSHA256 == originalSHA256 }),
                      original != nil || canBeAbsent else {
                    throw SwitchError("「\(first.1.name)」的游戏资源版本与此测试包不匹配。")
                }
                if let overFrame = card.overFrame {
                    guard RoyalFinish.supports(overFrame.cardID), overFrame.gate != path,
                          selected[overFrame.gate] == nil, !orderedPaths.contains(overFrame.gate),
                          overFrame.gate != gate, overFrame.gate != catalog,
                          overFrameGate == nil || overFrameGate == overFrame.gate else {
                        throw SwitchError("「\(card.name)」的超框登记与当前游戏版本不匹配。")
                    }
                    overFrameGate = overFrame.gate
                    overFrameCards[path] = overFrame.cardID
                    overFrameScope.insert(path)
                }
                after = try pack.verifiedBundle(variant, for: card)
                desired.files[path] = Entry(original: original, replacements: [variant.sha256])
                var entry = previous ?? Entry(original: original, replacements: [])
                entry.replacements.insert(variant.sha256)
                pending.files[path] = entry
            } else if let previous {
                after = previous.original
            } else {
                continue
            }
            if before != after { changes.append(Change(url: url, before: before, after: after, maxBytes: maxBytes)) }
        }
        if !overFrameScope.isEmpty, let overFrameGate {
            let resources = ResourceReuse(root: account.deletingLastPathComponent())
            let original = try resources.originalArtwork(account: account.lastPathComponent, path: overFrameGate)
            let url = try assetURL(overFrameGate)
            guard let before = try readFile(url) else { throw SwitchError("所选账号尚未下载超框登记资源。") }
            let previous = current.files[overFrameGate]
            guard before == original || previous?.replacements.contains(artworkDigest(before)) == true else {
                throw SwitchError("超框登记已被游戏或其他 Mod 更新，请先核对游戏资源。")
            }
            let after: Data
            if overFrameCards.isEmpty {
                after = original
            } else {
                let edit = editOverFrameGate ?? CardSearchEngine(storage: account).rewriteOverFrameGate
                after = try edit(original, Set(overFrameCards.values))
            }
            let hash = artworkDigest(after)
            if before != after {
                let change = Change(url: url, before: before, after: after, maxBytes: nil)
                let oldIDs = Set(current.overFrames?.cards.values.map { $0 } ?? [])
                if Set(overFrameCards.values).isSubset(of: oldIDs) {
                    changes.insert(change, at: 0)
                } else {
                    changes.append(change)
                }
            }
            desired.files[overFrameGate] = overFrameCards.isEmpty ? nil : Entry(original: original, replacements: [hash])
            desired.overFrames = overFrameCards.isEmpty ? nil : OverFrames(gate: overFrameGate, cards: overFrameCards)
            desired.pendingOverFramePaths = nil
            var backup = previous ?? Entry(original: original, replacements: [])
            backup.replacements.insert(hash)
            pending.files[overFrameGate] = backup
            pending.overFrames = OverFrames(gate: overFrameGate,
                cards: (current.overFrames?.cards ?? [:]).merging(overFrameCards) { _, new in new })
            pending.pendingOverFramePaths = overFrameScope
        }
        try checkGameClosed()
        try save(pending)
        var written: [Change] = []
        do {
            // Remove generated files only after their catalog entries and triggers are gone.
            for change in changes.filter({ $0.after != nil }) + changes.filter({ $0.after == nil }) {
                guard try readFile(change.url, maxBytes: change.maxBytes) == change.before else {
                    throw SwitchError("游戏文件刚刚发生变化，请退出游戏后重试。")
                }
                try write(change.after, to: change.url)
                written.append(change)
            }
            try save(desired)
        } catch {
            let failure = error
            do {
                for change in written.reversed() {
                    guard try readFile(change.url, maxBytes: change.maxBytes) == change.after else {
                        throw SwitchError("Mod 文件已发生变化。")
                    }
                    try write(change.before, to: change.url)
                }
                try save(current)
            } catch {
                let recovery = editingSummons ? "恢复原演出" : "恢复原卡图"
                throw SwitchError("写入未完成，已保留备份。退出游戏后点「\(recovery)」。")
            }
            throw failure
        }
        return Result(installed: selected.count, preserved: preserved)
    }

    private func state() throws -> State {
        guard let data = try readFile(journal, maxBytes: Self.journalLimit) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) throws {
        if state.files.isEmpty {
            if try readFile(journal, maxBytes: Self.journalLimit) != nil {
                try FileManager.default.removeItem(at: journal)
            }
        } else {
            let data = try JSONEncoder().encode(state)
            guard data.count <= Self.journalLimit else { throw SwitchError("卡图备份达到容量上限。") }
            try data.write(to: journal, options: .atomic)
        }
    }

    private func write(_ data: Data?, to url: URL) throws {
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func assetURL(_ path: String, allowMissingFolder: Bool = false) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].utf8.count == 8,
              parts[1].hasPrefix(parts[0]),
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SwitchError("Mod 资源路径格式异常。")
        }
        let folder = cache.appendingPathComponent(String(parts[0]))
        for url in [cache, folder] {
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT, url == folder, allowMissingFolder { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw SwitchError("游戏资源目录不是普通文件夹。")
            }
        }
        return folder.appendingPathComponent(String(parts[1]))
    }

    private func readFile(_ url: URL, maxBytes: Int? = nil) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw SwitchError("无法读取 Mod 或游戏资源。")
        }
        let limit = maxBytes ?? (url.lastPathComponent == "70e201b4" ? 16 : 4) * 1024 * 1024
        guard (info.st_mode & S_IFMT) == S_IFREG, (0...Int64(limit)).contains(info.st_size) else {
            throw SwitchError("Mod 或游戏资源文件格式异常。")
        }
        return try Data(contentsOf: url)
    }
}

func artworkDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

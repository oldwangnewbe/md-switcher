import Foundation

struct SearchCard: Codable, Identifiable {
    struct Variant: Codable, Identifiable {
        struct OverFrameSource: Codable {
            let file: String
            let gate: String?
        }

        let id: Int
        let file: String
        var overFrame: OverFrameSource?
    }

    let id: String
    let cid: Int?
    let masterName: String?
    let proName: String?
    let codes: [Int]
    let masterIDs: [Int]
    let variants: [Variant]
    let path: String?
    let series: [String]?
    var previewFile: String? = nil
    var originalPreviewPath: String? = nil
    var originalArtworkID: Int? = nil
    var performances: [SummonAnimation]? = nil

    var name: String { masterName ?? proName ?? id }
    var hasReplaceableArtwork: Bool { path != nil && !variants.isEmpty }

    func matchingPerformances(artworkID: Int?) -> [SummonAnimation] {
        guard let artworkID = artworkID ?? originalArtworkID else { return [] }
        return (performances ?? []).filter { $0.artworkID == artworkID }
    }

    var royalCardIDs: Set<Int> {
        guard let cid else { return [] }
        return Set(([cid] + masterIDs).filter(RoyalFinish.supports))
    }
}

struct CardSearchCatalog {
    private struct Entry {
        let card: SearchCard
        let names: [String]
        let series: [String]
    }

    struct Results {
        var series: [SearchCard] = []
        var names: [SearchCard] = []
        var cards: [SearchCard] { series + names }
    }

    let artDirectory: URL
    private let entries: [Entry]
    private let byCID: [Int: SearchCard]

    init(cards: [SearchCard], artDirectory: URL) {
        self.artDirectory = artDirectory
        entries = cards.map { card in
            let presets = ArtworkCollection.presets.compactMap { collection in
                card.cid.flatMap { collection.choices[$0] }.map { _ in collection.name }
            }
            return Entry(card: card, names: [card.masterName, card.proName].compactMap { $0 }.map(Self.normalized),
                         series: ((card.series ?? []) + presets).map(Self.normalized))
        }
        byCID = Dictionary(cards.compactMap { card in card.cid.map { ($0, card) } },
                           uniquingKeysWith: { first, _ in first })
    }

    func card(cid: Int) -> SearchCard? { byCID[cid] }
    func card(artworkPath: String) -> SearchCard? { entries.first { $0.card.path == artworkPath }?.card }
    var performances: [SummonAnimation] { entries.flatMap { $0.card.performances ?? [] } }

    func thumbnailURL(for card: SearchCard) -> URL? {
        card.previewFile.map { artDirectory.appendingPathComponent($0) }
    }

    func artworkPreview(for card: SearchCard, variant: SearchCard.Variant?) -> URL? {
        if let variant { return preview(variant) }
        return card.originalPreviewPath.map { artDirectory.deletingLastPathComponent().appendingPathComponent($0) }
    }

    func preview(_ variant: SearchCard.Variant) -> URL {
        let regular = artDirectory.appendingPathComponent(variant.file)
        guard let source = variant.overFrame, !FileManager.default.fileExists(atPath: regular.path) else { return regular }
        return artDirectory.deletingLastPathComponent().appendingPathComponent("OverFrame/\(source.file)")
    }

    func results(for query: String, onlyArtwork: Bool = false) -> Results {
        let query = Self.normalized(query)
        guard !query.isEmpty else { return Results() }
        if let number = Int(query) {
            return Results(names: entries.filter { entry in
                (!onlyArtwork || entry.card.hasReplaceableArtwork) &&
                    (entry.card.cid == number || entry.card.codes.contains(number) || entry.card.masterIDs.contains(number))
            }.prefix(60).map(\.card))
        }
        let seriesQuery = query.hasSuffix("系列") ? String(query.dropLast(2)) : query
        var seriesExact: [SearchCard] = []
        var seriesWithArtwork: [SearchCard] = []
        var seriesOther: [SearchCard] = []
        var exact: [SearchCard] = []
        var prefixes: [SearchCard] = []
        var matches: [SearchCard] = []
        for entry in entries {
            guard !onlyArtwork || entry.card.hasReplaceableArtwork else { continue }
            if entry.series.contains(seriesQuery) {
                if entry.names.contains(query) { seriesExact.append(entry.card) }
                else if entry.card.hasReplaceableArtwork { seriesWithArtwork.append(entry.card) }
                else { seriesOther.append(entry.card) }
                continue
            }
            if entry.names.contains(query) {
                exact.append(entry.card)
            } else if entry.names.contains(where: { $0.hasPrefix(query) }) {
                if prefixes.count < 60 { prefixes.append(entry.card) }
            } else if matches.count < 60 && entry.names.contains(where: { $0.contains(query) }) {
                matches.append(entry.card)
            }
        }
        return Results(series: seriesExact + seriesWithArtwork + seriesOther,
                       names: Array((exact + prefixes + matches).prefix(60)))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "zh_CN"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct CardSearchEngine {
    private struct SavedIndex: Codable {
        let fingerprint: String
        let cards: [SearchCard]
    }

    // Bump when card_search.py changes how it builds the search index.
    private static let indexFormat = 5
    // Keep in sync with the manifest emitted by card_search.py.
    private static let patchFormat = 1
    let storage: URL
    var proDirectory: URL? = nil

    private func requireMDPro3() throws -> URL {
        guard let proDirectory else {
            throw SwitchError("找不到 MDPro3 卡库和卡图。请在「设置 → 安装目录」选择 MDPro3 文件夹。")
        }
        return proDirectory
    }

    private var library: URL { storage.appendingPathComponent("card-art-library") }

    func index(cache: URL) throws -> CardSearchCatalog {
        let fm = FileManager.default
        let proDirectory = try requireMDPro3()
        guard InstallationPaths.isMDPro3(proDirectory) else {
            throw SwitchError("MDPro3 卡库或卡图已移动。请在「设置 → 安装目录」重新选择。")
        }
        let art = proDirectory.appendingPathComponent("Picture/Art")
        let savedFile = storage.appendingPathComponent("card-search-index.json")
        let fingerprint = try indexFingerprint(cache: cache, art: art, proDirectory: proDirectory)
        if let data = try? Data(contentsOf: savedFile),
           let saved = try? JSONDecoder().decode(SavedIndex.self, from: data),
           saved.fingerprint == fingerprint, !saved.cards.isEmpty {
            return CardSearchCatalog(cards: saved.cards, artDirectory: art)
        }

        let work = try temporaryDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? fm.removeItem(at: work) }
        let output = work.appendingPathComponent("index.json")
        var arguments = ["index", cache.path, proDirectory.path, output.path, "--over-frame"]
        let account = cache.deletingLastPathComponent()
        let resources = ResourceReuse(root: account.deletingLastPathComponent())
        let metadata = [SummonAnimation.catalogPath, SummonAnimation.gatePath]
        if metadata.allSatisfy({ fm.fileExists(atPath: cache.appendingPathComponent($0).path) }) {
            let inputs = try metadata.map { path in
                let file = work.appendingPathComponent(String(path.suffix(8)))
                try resources.originalArtwork(account: account.lastPathComponent, path: path).write(to: file)
                return file.path
            }
            arguments += ["--performance-metadata"] + inputs
        }
        try run(arguments, in: work)
        let cards = try JSONDecoder().decode([SearchCard].self, from: Data(contentsOf: output))
        guard !cards.isEmpty else { throw SwitchError("本机卡库没有可索引的卡片。") }
        guard fingerprint == (try? indexFingerprint(cache: cache, art: art, proDirectory: proDirectory)) else {
            throw SwitchError("建立索引时游戏卡库或 MDPro3 素材发生了变化，请重试。")
        }
        if let data = try? JSONEncoder().encode(SavedIndex(fingerprint: fingerprint, cards: cards)),
           (try? fm.createDirectory(at: storage, withIntermediateDirectories: true)) != nil {
            try? data.write(to: savedFile, options: .atomic)
        }
        return CardSearchCatalog(cards: cards, artDirectory: art)
    }

    private func indexFingerprint(cache: URL, art: URL, proDirectory: URL) throws -> String {
        let fm = FileManager.default
        var parts = [String(Self.indexFormat), cache.path, proDirectory.path]
        let manifest = cache.appendingPathComponent(ResourceReuse.indexPath)
        let database = proDirectory.appendingPathComponent("Data/locales/zh-CN/cards.cdb")
        let mapping = proDirectory.appendingPathComponent("Data/cards_Lite.json")
        for file in [manifest, database, mapping] {
            parts.append(artworkDigest(try Data(contentsOf: file)))
        }
        let wal = database.deletingLastPathComponent().appendingPathComponent(database.lastPathComponent + "-wal")
        for file in [wal,
                     proDirectory.appendingPathComponent("Data/locales/zh-CN/strings.conf")] {
            parts.append(fm.fileExists(atPath: file.path) ? artworkDigest(try Data(contentsOf: file)) : "-")
        }

        // The game manifest versions the assets. Track downloaded filenames separately so
        // adding a missing bundle is noticed, while replacing an existing artwork is ignored.
        for folder in try fm.contentsOfDirectory(atPath: cache.path).sorted()
        where folder.utf8.count == 2 && UInt8(folder, radix: 16) != nil {
            let directory = cache.appendingPathComponent(folder)
            parts += try fm.contentsOfDirectory(atPath: directory.path).filter {
                $0.utf8.count == 8 && $0.hasPrefix(folder) && UInt32($0, radix: 16) != nil
            }.sorted()
        }

        let artFolders = [art, art.deletingLastPathComponent().appendingPathComponent("OverFrame")]
        for directory in artFolders {
            parts.append(directory.lastPathComponent)
            guard fm.fileExists(atPath: directory.path) else { continue }
            for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
                let file = name as NSString
                let code = file.deletingPathExtension.utf8
                guard !code.isEmpty, code.allSatisfy({ (48...57).contains($0) }),
                      ["jpg", "jpeg", "png"].contains(file.pathExtension.lowercased()) else { continue }
                var info = stat()
                guard stat(directory.path + "/" + name, &info) == 0 else {
                    if errno == ENOENT { continue }
                    throw SwitchError("无法检查 MDPro3 卡图是否有更新。")
                }
                if (info.st_mode & S_IFMT) == S_IFREG {
                    parts.append("\(name):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)")
                }
            }
        }
        let animation = proDirectory.appendingPathComponent("MDPro3_Data/StandaloneWindows64/MonsterCutin2")
        if let files = try? fm.contentsOfDirectory(at: animation, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where Int(file.lastPathComponent) != nil {
                let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                parts.append("\(file.lastPathComponent):\(stamp.fileSize ?? 0):\(stamp.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        return artworkDigest(Data(parts.joined(separator: "\0").utf8))
    }

    func makePack(card: SearchCard, variant: SearchCard.Variant, original: Data) throws -> SkyStrikerPack {
        let filename = variant.overFrame?.file ?? variant.file
        guard let path = card.path, let cid = card.cid, let destination = packDirectory(path: path, id: variant.id),
              filename.range(of: #"^[0-9]+\.(jpg|jpeg|png)$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw SwitchError("尚未匹配到可替换的《大师决斗》卡图。")
        }
        let overFrame: SkyStrikerPack.Card.OverFrame?
        if let source = variant.overFrame {
            guard let gate = source.gate else {
                throw SwitchError("缺少大师决斗的超框登记资源，请先完成游戏内更新。")
            }
            overFrame = .init(cardID: cid, gate: gate)
        } else {
            overFrame = nil
        }
        let folder = overFrame == nil ? "Art" : "OverFrame"
        let image = try Data(contentsOf: requireMDPro3().appendingPathComponent("Picture/\(folder)/\(filename)"))
        let source = SkyStrikerPack.Card.SourceArtwork(format: overFrame == nil ? Self.patchFormat : 2,
                                                       cid: cid, sha256: artworkDigest(image))
        let originalSHA256 = artworkDigest(original)
        func checkedPack(in directory: URL) throws -> SkyStrikerPack {
            let pack = try SkyStrikerPack(directory: directory)
            guard let entry = pack.cards.first, entry.path == path, entry.originalSHA256 == originalSHA256,
                  entry.sourceArtwork == source, entry.overFrame == overFrame, let replacement = entry.variants.first(where: { $0.id == variant.id }) else {
                throw SwitchError("卡图包与当前游戏资源或 MDPro3 素材不匹配。")
            }
            _ = try pack.verifiedBundle(replacement, for: entry)
            return pack
        }
        if let cached = try? checkedPack(in: destination) { return cached }

        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let work = try temporaryDirectory(in: library)
        defer { try? fm.removeItem(at: work) }
        let input = work.appendingPathComponent("original")
        let artwork = work.appendingPathComponent(filename)
        let output = work.appendingPathComponent("pack")
        try original.write(to: input)
        try image.write(to: artwork)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        var arguments = ["patch", input.path, artwork.path, String(cid), path, String(variant.id), card.name, output.path]
        if let overFrame { arguments += ["--over-frame-gate", overFrame.gate] }
        try run(arguments, in: work)
        _ = try checkedPack(in: output)
        if renameatx_np(AT_FDCWD, output.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST,
                  renameatx_np(AT_FDCWD, output.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw SwitchError("无法更新本地卡图包。")
            }
        }
        return try checkedPack(in: destination)
    }

    func savedPack(path: String, id: Int) -> SkyStrikerPack? {
        guard let directory = packDirectory(path: path, id: id) else { return nil }
        return try? SkyStrikerPack(directory: directory)
    }

    func hasOverFrameSource(_ id: Int) -> Bool {
        guard let proDirectory else { return false }
        return ["png", "jpg", "jpeg"].contains { ext in
            FileManager.default.fileExists(atPath: proDirectory.appendingPathComponent("Picture/OverFrame/\(id).\(ext)").path)
        }
    }

    func overFramePacks(for choices: [String: Int], resources: ResourceReuse, source: String) throws -> [SkyStrikerPack] {
        let candidates = choices.filter { hasOverFrameSource($0.value) }
        guard !candidates.isEmpty else { return [] }
        let catalog = try index(cache: resources.artworkCache(account: source))
        return try candidates.map { path, id in
            guard let card = catalog.card(artworkPath: path),
                  let variant = card.variants.first(where: { $0.id == id && $0.overFrame != nil }) else {
                throw SwitchError("无法匹配编号 \(id) 的超框异画，请重新从卡片搜索选择。")
            }
            let original = try resources.originalArtwork(account: source, path: path)
            return try makePack(card: card, variant: variant, original: original)
        }
    }

    func rewriteOverFrameGate(_ original: Data, cardIDs: Set<Int>) throws -> Data {
        guard !cardIDs.isEmpty else { return original }
        let work = try temporaryDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent("original")
        let output = work.appendingPathComponent("over-frame-table")
        try original.write(to: input)
        try run(["over-frame-gate", input.path, output.path] + cardIDs.sorted().map(String.init), in: work)
        let data = try Data(contentsOf: output)
        guard data.starts(with: Data("UnityFS\0".utf8)) else { throw SwitchError("超框登记资源格式异常。") }
        return data
    }

    func makeSummonPack(cache: URL, originals: [String: Data], selected: Set<SummonAnimation>,
                        work: URL) throws -> SkyStrikerPack {
        let pro = selected.allSatisfy(\.sourceAvailableWithoutMDPro3) ? work : try requireMDPro3()
        let input = work.appendingPathComponent("originals")
        let output = work.appendingPathComponent("pack")
        let fm = FileManager.default
        try fm.createDirectory(at: input, withIntermediateDirectories: false)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        for (path, data) in originals {
            try data.write(to: input.appendingPathComponent(String(path.suffix(8))))
        }
        let cards = selected.sorted { $0.cid < $1.cid }.map {
            "\($0.cid):\($0.artworkID):\($0.donor ?? 0):\($0.packKind)"
        }
        try run(["summon", cache.path, input.path, output.path, pro.path] + cards, in: work)
        return try SkyStrikerPack(directory: output)
    }

    private func packDirectory(path: String, id: Int) -> URL? {
        guard id > 0, path.range(of: #"^[0-9a-f]{2}/[0-9a-f]{8}$"#, options: .regularExpression) != nil else { return nil }
        return library.appendingPathComponent("\(path.suffix(8))-\(id)")
    }

    private func temporaryDirectory(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("card-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func run(_ arguments: [String], in work: URL) throws {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("CardSearch"),
              FileManager.default.fileExists(atPath: helper.appendingPathComponent("site.zip").path) else {
            throw SwitchError("这个构建缺少卡片搜索组件。")
        }
        let errorURL = work.appendingPathComponent("helper.log")
        try Data().write(to: errorURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-s", "-B", helper.appendingPathComponent("card_search.py").path] + arguments
        process.environment = ["MD_SWITCHER_WORK": work.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + 90) == .success else {
            process.terminate()
            throw SwitchError("读取或生成卡图超时，请重试。")
        }
        guard process.terminationStatus == 0 else {
            let log = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            let detail = log.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            let message = switch arguments.first {
            case "index": "读取卡片索引失败。"
            case "summon": "无法准备卡片演出。"
            case "over-frame-gate": "无法更新超框登记。"
            default: "无法生成这张卡的替换资源。"
            }
            throw SwitchError(message + String(detail.prefix(240)))
        }
    }
}

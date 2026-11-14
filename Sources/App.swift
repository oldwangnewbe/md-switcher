import SwiftUI

@main
struct MDSwitcherApp: App {
    @StateObject private var model = SwitcherModel()
    @NSApplicationDelegateAdaptor(SwitcherAppDelegate.self) private var delegate

    var body: some Scene {
        Window("决斗匣", id: "main") {
            SwitcherMainWindow(model: model, delegate: delegate)
        }
        .defaultSize(width: 950, height: 610)
        .windowResizability(.contentMinSize)
    }
}

private struct SwitcherMainWindow: View {
    @Environment(\.openWindow) private var openWindow
    let model: SwitcherModel
    let delegate: SwitcherAppDelegate

    var body: some View {
        SwitcherWorkspace(model: model)
            .frame(minWidth: 810, idealWidth: 950, minHeight: 510, idealHeight: 610)
            .onAppear {
                delegate.openMainWindow = { [openWindow] in openWindow(id: "main") }
                model.load()
            }
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published private(set) var installation: SteamInstallation?
    @Published private(set) var proDirectory: URL?
    @Published private(set) var installationPathError: String?

    private static let gamePathKey = "masterDuelInstallationPath"
    private static let proPathKey = "mdPro3InstallationPath"
    @Published private(set) var accounts: [SteamAccount] = []
    @Published var selectedID: UInt64?
    @Published var renameAccount: SteamAccount?
    @Published private(set) var artworkCollections = ArtworkCollection.load() {
        didSet { ArtworkCollection.save(artworkCollections) }
    }
    @Published var alias = ""
    @Published private(set) var verifiedID: UInt64?
    @Published private(set) var busy = false
    @Published private(set) var recoveryNeeded = false
    @Published private(set) var status = "正在查找 CrossOver 中的 Master Duel…"
    @Published private(set) var error = false
    @Published var artworkConfirmation: ArtworkConfirmation?

    struct ArtworkConfirmation {
        let message: String
        let apply: (Bool) -> Void
    }

    private struct QueuedArtworkChoice: Codable {
        let artworkID: Int
        let includePerformance: Bool
    }
    @Published private(set) var royalFinishByAccount =
        UserDefaults.standard.dictionary(forKey: "royalFinishByAccount") as? [String: [Int]] ?? [:] {
        didSet { UserDefaults.standard.set(royalFinishByAccount, forKey: "royalFinishByAccount") }
    }
    @Published private(set) var aliases = UserDefaults.standard.dictionary(forKey: "aliases") as? [String: String] ?? [:]
    @Published private(set) var resourceFolders =
        UserDefaults.standard.dictionary(forKey: "resourceFolders") as? [String: String] ?? [:]
    @Published private(set) var mainAccounts =
        UserDefaults.standard.dictionary(forKey: "resourceMainAccounts") as? [String: String] ?? [:]
    @Published var reuseMainLanguage = UserDefaults.standard.bool(forKey: "reuseGameSettings") {
        didSet { UserDefaults.standard.set(reuseMainLanguage, forKey: "reuseGameSettings") }
    }

    private var queuedArtwork = SwitcherModel.loadQueuedArtwork() {
        didSet {
            if let data = try? PropertyListEncoder().encode(queuedArtwork) {
                UserDefaults.standard.set(data, forKey: "queuedCardArtwork")
            }
        }
    }

    private static func loadQueuedArtwork() -> [String: [String: QueuedArtworkChoice]] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "queuedCardArtwork"),
           let choices = try? PropertyListDecoder().decode([String: [String: QueuedArtworkChoice]].self, from: data) {
            return choices
        }
        var current = defaults.dictionary(forKey: "queuedCardArtwork") as? [String: [String: Int]] ?? [:]
        if let previous = defaults.dictionary(forKey: "queuedSkyStrikerArtwork") as? [String: [String: Int]],
           let pack = try? SkyStrikerPack.bundled() {
            for (account, selected) in previous {
                for card in pack.cards where current[account]?[card.path] == nil {
                    current[account, default: [:]][card.path] = selected[card.path] ?? 0
                }
            }
            defaults.set(current, forKey: "queuedCardArtwork")
            defaults.removeObject(forKey: "queuedSkyStrikerArtwork")
        }
        return current.mapValues { $0.mapValues { QueuedArtworkChoice(artworkID: $0, includePerformance: true) } }
    }
    private let worker = DispatchQueue(label: "md-switcher")
    private let steamRoyalFinishMonitor = SteamRoyalFinishMonitor()
    private var steamMonitorTimer: Timer?
    private var checkingSteamLaunch = false
    var selected: SteamAccount? { accounts.first(where: { $0.id == selectedID }) }
    var mainResourceAccount: UInt64? {
        guard let installation, let value = mainAccounts[installation.bottle.path] else { return nil }
        return UInt64(value)
    }
    var resourceTarget: String? {
        guard let installation, let selected,
              let name = resourceFolders[resourceKey(installation, selected.id)],
              let reuse = Switcher(installation: installation).resources,
              (try? reuse.accountDirectories().contains(name)) == true else { return nil }
        return name
    }

    var canRestoreResources: Bool {
        guard let installation, let resourceTarget else { return false }
        return Switcher(installation: installation).resources?.hasBackup(for: resourceTarget) == true
    }

    func load() {
        guard !busy else { return }
        refresh(updateStatus: true)
        if steamMonitorTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkSteamLaunch() }
            }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            steamMonitorTimer = timer
        }
    }

    private func checkSteamLaunch() {
        guard !busy, !recoveryNeeded, !checkingSteamLaunch, !royalFinishByAccount.isEmpty,
              let installation else { return }
        checkingSteamLaunch = true
        let switcher = Switcher(installation: installation)
        let monitor = steamRoyalFinishMonitor
        let selections = royalFinishByAccount
        worker.async { [weak self] in
            let result = Result { try monitor.poll(switcher: switcher, selections: selections) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                checkingSteamLaunch = false
                guard !busy, self.installation?.game == installation.game else { return }
                switch result {
                case .success(true):
                    error = false
                    status = "检测到 Steam 已启动 Master Duel。动态镜碎已加载。"
                case .success(false): break
                case .failure(let failure):
                    error = true
                    status = "动态镜碎未自动加载。\(failure.localizedDescription)"
                }
            }
        }
    }

    private func refresh(updateStatus: Bool) {
        proDirectory = InstallationPaths.discoverMDPro3(preferred: savedDirectory(Self.proPathKey))
        do {
            let installation = try SteamInstallation.discover(preferredGame: savedDirectory(Self.gamePathKey))
            let accounts = FileManager.default.fileExists(atPath: installation.loginFile.path)
                ? try LoginUsers(installation.readLoginFile()).accounts : []
            if self.installation?.game != installation.game { verifiedID = nil }
            self.installation = installation
            self.accounts = accounts
            recoveryNeeded = Switcher(installation: installation).hasPendingRecovery
            if !accounts.contains(where: { $0.id == selectedID }) {
                selectedID = accounts.first(where: { $0.preferred && $0.remembered })?.id
                    ?? accounts.first(where: \.remembered)?.id
            }
            if updateStatus {
                error = recoveryNeeded
                status = if recoveryNeeded {
                    "发现未完成的配置写入。请退出 Steam，再恢复登录设置。"
                } else if accounts.isEmpty {
                    "请先在 Steam 中登录账号并选择记住登录，然后刷新。"
                } else {
                    "请选择一个账号。换号前请先退出游戏。"
                }
            }
        } catch {
            installation = nil
            accounts = []
            recoveryNeeded = false
            self.error = true
            status = error.localizedDescription
        }
    }

    private func savedDirectory(_ key: String) -> URL? {
        UserDefaults.standard.string(forKey: key).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func chooseInstallationDirectory(mdPro3: Bool) {
        guard !busy else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "选取"
        picker.message = mdPro3 ? "请选择包含 Data 和 Picture 的 MDPro3 文件夹。"
            : "请选择包含 masterduel.exe 的游戏文件夹。"
        picker.directoryURL = mdPro3 ? proDirectory : installation?.game
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        do {
            if mdPro3 {
                guard InstallationPaths.isMDPro3(folder) else {
                    throw SwitchError("这个文件夹缺少 MDPro3 的简中卡库、卡片映射或卡图。")
                }
            } else {
                _ = try SteamInstallation.discover(preferredGame: folder, requirePreferred: true)
            }
            UserDefaults.standard.set(InstallationPaths.canonical(folder).path,
                                      forKey: mdPro3 ? Self.proPathKey : Self.gamePathKey)
            installationPathError = nil
            load()
        } catch {
            installationPathError = error.localizedDescription
        }
    }

    func resetInstallationDirectory(mdPro3: Bool) {
        guard !busy else { return }
        UserDefaults.standard.removeObject(forKey: mdPro3 ? Self.proPathKey : Self.gamePathKey)
        installationPathError = nil
        load()
    }

    func rename(_ account: SteamAccount, to label: String) {
        let alias = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        aliases[String(account.id)] = alias.isEmpty ? nil : alias
        UserDefaults.standard.set(aliases, forKey: "aliases")
    }

    var selectedRoyalFinishCardIDs: Set<Int> {
        guard let selectedID else { return [] }
        return Set(royalFinishByAccount[String(selectedID)] ?? [])
    }

    func hasRoyalFinish(for cardIDs: Set<Int>) -> Bool {
        !cardIDs.isEmpty && cardIDs.isSubset(of: selectedRoyalFinishCardIDs)
    }

    func setRoyalFinish(_ cardIDs: Set<Int>, enabled: Bool, all: Bool = false) {
        guard !busy, let selectedID else { return }
        let ids = cardIDs.filter(RoyalFinish.supports)
        guard !ids.isEmpty else { return }
        let accountsToEdit = all ? accounts.map(\.id) : [selectedID]
        var settings = royalFinishByAccount
        for account in accountsToEdit {
            let key = String(account)
            var current = Set(settings[key] ?? [])
            if enabled { current.formUnion(ids) }
            else { current.subtract(ids) }
            settings[key] = current.isEmpty ? nil : current.sorted()
        }
        royalFinishByAccount = settings
        error = false
        status = enabled ? "已开启动态镜碎。下次启动游戏时自动加载。"
            : "已关闭所选卡片的动态镜碎。"
    }

    func switchAccount(launchGame: Bool, identifyNewResources: Bool = false) {
        guard !busy, !recoveryNeeded, let account = selected, account.remembered,
              let installation else { return }
        let switcher = Switcher(installation: installation, proDirectory: proDirectory)
        let syncLanguage = reuseMainLanguage
        let key = resourceKey(installation, account.id)
        let prefix = installation.bottle.path + "|"
        let plan: Switcher.ResourceLaunch?
        if launchGame, !identifyNewResources, let mainResourceAccount, account.id != mainResourceAccount {
            guard let source = UserDefaults.standard.string(forKey: "resourceSource|\(installation.bottle.path)") else {
                finish("找不到资源主账号目录，请检查游戏资源设置。", failed: true)
                return
            }
            let otherAccounts = Set(resourceFolders.compactMap { mapping, folder in
                mapping.hasPrefix(prefix) && mapping != key ? folder : nil
            })
            plan = Switcher.ResourceLaunch(source: source, target: resourceTarget, otherAccounts: otherAccounts)
        } else {
            plan = nil
        }
        let queuedSelection = plan != nil ? queuedArtwork[key] : nil
        let royalCardIDs = Set(royalFinishByAccount[String(account.id)] ?? [])
        let knownResourceFolder = launchGame && !identifyNewResources && account.id == mainResourceAccount
            ? artworkSource(for: installation) : nil
        begin(launchGame ? "正在准备启动 Master Duel…" : "正在准备换号…")
        worker.async { [weak self] in
            do {
                var warnings: [String] = []
                var royalFinishApplied = false
                let artwork: ArtworkEdit?
                if let queuedSelection, let plan, let resources = switcher.resources {
                    do {
                        let choices = queuedSelection.mapValues(\.artworkID)
                        let optOut = Set(queuedSelection.keys.filter { queuedSelection[$0]?.includePerformance == false })
                        let library = CardSearchEngine(storage: switcher.storage, proDirectory: switcher.proDirectory)
                        var packs = try library.overFramePacks(for: choices, resources: resources, source: plan.source)
                        packs += choices.compactMap { path, id in library.savedPack(path: path, id: id) }
                        if let bundled = try? SkyStrikerPack.bundled() { packs.append(bundled) }
                        artwork = ArtworkEdit(choices: choices, packs: packs, performanceOptOut: optOut)
                    } catch {
                        warnings.append("排队的异画尚未应用。\(error.localizedDescription)")
                        artwork = nil
                    }
                } else {
                    artwork = nil
                }
                let folder = try switcher.changeAccount(to: account.id, launchGame: launchGame,
                    identifyNewResources: identifyNewResources, resourceLaunch: plan, syncMainLanguage: syncLanguage,
                    queuedArtwork: artwork, knownResourceFolder: knownResourceFolder,
                    royalFinish: royalCardIDs,
                    recordResourceDirectory: { folder in
                        DispatchQueue.main.async { [weak self] in self?.recordResourceDirectory(folder, for: key) }
                    }) { progress in
                    switch progress {
                    case .gameLanguageWarning(let reason), .artworkWarning(let reason),
                         .royalFinishWarning(let reason): warnings.append(reason)
                    case .royalFinishApplied: royalFinishApplied = true
                    default: break
                    }
                    DispatchQueue.main.async { [weak self] in
                        if case .queuedArtworkApplied = progress { self?.queuedArtwork[key] = nil }
                        self?.status = progress.title
                    }
                }
                let warning = warnings.joined(separator: " ")
                let royalStatus = royalFinishApplied ? "动态镜碎已加载。" : ""
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    verifiedID = account.id
                    let name = aliases[String(account.id)] ?? account.displayName
                    if let folder {
                        recordResourceDirectory(folder, for: key)
                        finish("已识别「\(name)」的资源目录。退出游戏后，在「游戏资源」中选择「复用已下载资源」。")
                    } else {
                        let message = launchGame ? "已用「\(name)」启动 Master Duel。" : "已确认 Steam 登录「\(name)」。"
                        finish(message + royalStatus + warning)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.finish(message, failed: true) }
            }
        }
    }

    func updateResources(restore: Bool) {
        guard !busy, !recoveryNeeded, let installation, let target = resourceTarget else { return }
        let switcher = Switcher(installation: installation)
        let sourceKey = "resourceSource|\(installation.bottle.path)"
        let source = UserDefaults.standard.string(forKey: sourceKey)
        begin(restore ? "正在恢复新号的原资源…" : "正在核对游戏资源和索引…")
        worker.async { [weak self] in
            do {
                if restore {
                    try switcher.restoreResources(target: target, source: source)
                    DispatchQueue.main.async { [weak self] in self?.finish("新号的原资源目录已恢复。") }
                } else {
                    guard let source else { throw SwitchError("请先设置提供完整资源的主账号。") }
                    let result = try switcher.prepareResources(target: target, source: source)
                    DispatchQueue.main.async { [weak self] in
                        let status = result.clonedFiles == 0
                            ? "资源索引已补齐。现在可以启动新号。"
                            : "已复用 \(result.clonedFiles) 个资源文件，并补齐索引。现在可以启动新号。"
                        self?.finish(status)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.finish(message, failed: true) }
            }
        }
    }

    private var modContext: (switcher: Switcher, target: String)? {
        guard let installation, let account = selected, let source = artworkSource(for: installation),
              let target = artworkTarget(account.id, installation: installation, source: source) else { return nil }
        let switcher = Switcher(installation: installation, proDirectory: proDirectory)
        guard let resources = switcher.resources,
              (try? resources.accountDirectories().contains(target)) == true else { return nil }
        return (switcher, target)
    }

    private func artworkSource(for installation: SteamInstallation) -> String? {
        guard mainResourceAccount != nil else { return nil }
        return UserDefaults.standard.string(forKey: "resourceSource|\(installation.bottle.path)")
    }

    private func artworkTarget(_ account: UInt64, installation: SteamInstallation, source: String) -> String? {
        let key = resourceKey(installation, account)
        let isMain = account == mainResourceAccount
        guard let target = isMain ? source : resourceFolders[key], isMain || target != source else { return nil }
        guard !resourceFolders.contains(where: {
            $0.key != key && $0.key.hasPrefix(installation.bottle.path + "|") && $0.value == target
        }) else { return nil }
        return target
    }

    var canManageMods: Bool { !busy && !recoveryNeeded && modContext != nil }
    var canApplyArtworkToAll: Bool {
        guard !busy, !recoveryNeeded, !accounts.isEmpty, let installation else { return false }
        return artworkSource(for: installation) != nil
    }

    func artworkSelections() throws -> [String: Int] {
        var selections: [String: Int] = [:]
        if let context = modContext, let resources = context.switcher.resources {
            selections = try SkyStrikerMod(resources: resources, account: context.target).selections()
        }
        if let installation, let account = selected, let queued = queuedArtwork[resourceKey(installation, account.id)] {
            for (path, choice) in queued { selections[path] = choice.artworkID > 0 ? choice.artworkID : nil }
        }
        return selections
    }

    func summonSelections(catalog: [SummonAnimation] = []) throws -> Set<SummonAnimation> {
        guard let context = modContext, let resources = context.switcher.resources else { return [] }
        return try SkyStrikerMod(resources: resources, account: context.target).summonSelections(catalog: catalog)
    }

    func updateSummonAnimation(_ selected: Set<SummonAnimation>, completed: @escaping (Bool) -> Void) {
        guard canManageMods, let context = modContext else { return }
        begin(selected.isEmpty ? "正在恢复原演出…" : "正在准备卡片演出…")
        worker.async { [weak self] in
            let result = Result { try context.switcher.updateSummonAnimation(target: context.target, selected: selected) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    var message = selected.isEmpty ? "已恢复所选账号的原演出。"
                        : "已应用 \(selected.count) 张卡的演出。可进入单人模式测试。"
                    if outcome.preserved > 0 { message += "已保留 \(outcome.preserved) 个被游戏或其他 Mod 更新的文件。" }
                    finish(message)
                    completed(true)
                case .failure(let error):
                    finish(error.localizedDescription, failed: true)
                    completed(false)
                }
            }
        }
    }

    func loadCardSearch() async throws -> CardSearchCatalog {
        try Task.checkCancellation()
        guard let installation, let source = artworkSource(for: installation),
              let resources = Switcher(installation: installation).resources else {
            throw SwitchError("请先设置并下载主账号的游戏资源。")
        }
        let engine = CardSearchEngine(storage: Switcher(installation: installation).storage, proDirectory: proDirectory)
        return try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result { try engine.index(cache: resources.artworkCache(account: source)) })
            }
        }
    }

    func applySearchCard(_ card: SearchCard, variant: SearchCard.Variant?, all: Bool, started: @escaping () -> Void,
                         completed: @escaping () -> Void) {
        applyCards([(card, variant)], all: all, started: started, completed: completed)
    }

    func createArtworkCollection(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw SwitchError("合集名称请填写 1 到 40 个字符。") }
        guard !artworkCollections.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { throw SwitchError("已有同名合集。") }
        let id = UUID().uuidString
        artworkCollections.append(ArtworkCollection(id: id, name: name, choices: [:]))
        return id
    }

    func setArtworkCollectionChoice(_ collection: String, cid: Int, variant: Int?) {
        guard let index = artworkCollections.firstIndex(where: { $0.id == collection }) else { return }
        artworkCollections[index].choices[cid] = variant
    }

    func applyArtworkCollection(_ collection: ArtworkCollection, catalog: CardSearchCatalog,
                                restore: Bool, all: Bool, started: @escaping () -> Void) {
        var cards: [(SearchCard, SearchCard.Variant?)] = []
        for entry in collection.cards(in: catalog) where entry.hasArtworkChoice {
            guard let card = entry.card, card.path != nil, restore || entry.variant != nil else {
                started()
                finish("「\(entry.card?.name ?? String(entry.id))」的卡图资源或异画已找不到，请先调整合集。", failed: true)
                return
            }
            cards.append((card, restore ? nil : entry.variant))
        }
        applyCards(cards, all: all, started: started, completed: {})
    }

    private func applyCards(_ cards: [(SearchCard, SearchCard.Variant?)], all: Bool,
                            started: @escaping () -> Void, completed: @escaping () -> Void) {
        guard !cards.isEmpty, let installation, let source = artworkSource(for: installation) else { return }
        var choices: [String: Int] = [:]
        for (card, variant) in cards {
            guard let path = card.path, choices.updateValue(variant?.id ?? 0, forKey: path) == nil else {
                started()
                finish("「\(card.name)」的卡图路径未匹配或重复。", failed: true)
                return
            }
        }
        let switcher = Switcher(installation: installation)
        let proDirectory = self.proDirectory
        let makePacks: () throws -> [SkyStrikerPack] = {
            guard let resources = switcher.resources else { throw SwitchError("找不到 Master Duel 游戏目录。") }
            let engine = CardSearchEngine(storage: switcher.storage, proDirectory: proDirectory)
            return try cards.compactMap { card, variant in
                guard let path = card.path, let variant else { return nil }
                do {
                    let original = try resources.originalArtwork(account: source, path: path)
                    return try engine.makePack(card: card, variant: variant, original: original)
                } catch {
                    throw SwitchError("「\(card.name)」：\(error.localizedDescription)")
                }
            }
        }
        let matches = Dictionary(uniqueKeysWithValues: cards.compactMap { card, variant -> (String, [SummonAnimation])? in
            guard let path = card.path, let variant else { return nil }
            let options = card.matchingPerformances(artworkID: variant.id)
            return options.isEmpty ? nil : (path, options)
        })
        let name = cards.count == 1 ? cards.first?.0.name : nil
        confirmArtwork(choices, matches: matches, name: name) { [weak self] optOut in
            started()
            self?.applyArtwork(choices, all: all, performanceOptOut: optOut, makePacks: makePacks, completed: completed)
        }
    }

    func updateSkyStriker(_ selection: [String: Int], pack: SkyStrikerPack, all: Bool = false,
                          completed: @escaping () -> Void) {
        guard let installation, let source = artworkSource(for: installation) else { return }
        let switcher = Switcher(installation: installation, proDirectory: proDirectory)
        let choices = Dictionary(uniqueKeysWithValues: pack.cards.map { ($0.path, selection[$0.path] ?? 0) })
        let makePacks: () throws -> [SkyStrikerPack] = {
            guard let resources = switcher.resources else { return [pack] }
            let engine = CardSearchEngine(storage: switcher.storage, proDirectory: switcher.proDirectory)
            return try engine.overFramePacks(for: choices, resources: resources, source: source) + [pack]
        }
        if proDirectory == nil || !choices.values.contains(where: { $0 > 0 }) {
            applyArtwork(choices, all: all, performanceOptOut: Set(choices.keys), makePacks: makePacks, completed: completed)
            return
        }
        begin("正在检查异画演出…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await loadCardSearch()
                let matches = choices.reduce(into: [String: [SummonAnimation]]()) { result, choice in
                    guard choice.value > 0, let card = catalog.card(artworkPath: choice.key) else { return }
                    let options = card.matchingPerformances(artworkID: choice.value)
                    if !options.isEmpty { result[choice.key] = options }
                }
                finish("")
                confirmArtwork(choices, matches: matches, name: nil) { [weak self] optOut in
                    self?.applyArtwork(choices, all: all, performanceOptOut: optOut, makePacks: makePacks, completed: completed)
                }
            } catch {
                finish(error.localizedDescription, failed: true)
            }
        }
    }

    private func confirmArtwork(_ choices: [String: Int], matches: [String: [SummonAnimation]], name: String?,
                                apply: @escaping (Set<String>) -> Void) {
        let paths = Set(choices.keys)
        guard !matches.isEmpty else {
            apply(paths)
            return
        }
        let message: String
        if let name, let options = matches.values.first {
            let categories = SummonAnimation.Category.allCases.filter { category in options.contains { $0.category == category } }
            let labels = categories.map(\.rawValue).joined(separator: "、")
            message = "「\(name)」的这款异画支持\(labels)。"
        } else {
            message = "本次有 \(matches.count) 张异画可同步新增或替换演出。"
        }
        artworkConfirmation = ArtworkConfirmation(message: message) { includePerformance in
            apply(includePerformance ? paths.subtracting(matches.keys) : paths)
        }
    }

    private func applyArtwork(_ choices: [String: Int], all: Bool, performanceOptOut: Set<String>,
                              makePacks: @escaping () throws -> [SkyStrikerPack], completed: @escaping () -> Void) {
        if all {
            applyArtworkToAll(choices, performanceOptOut: performanceOptOut, makePacks: makePacks, completed: completed)
        } else {
            updateArtwork(choices, performanceOptOut: performanceOptOut, makePacks: makePacks, completed: completed)
        }
    }

    private func updateArtwork(_ choices: [String: Int], performanceOptOut: Set<String>,
                               makePacks: @escaping () throws -> [SkyStrikerPack],
                               completed: @escaping () -> Void) {
        guard canManageMods, let context = modContext, let installation, let account = selected,
              let source = artworkSource(for: installation) else { return }
        let key = resourceKey(installation, account.id)
        let edit = ArtworkEdit(choices: choices, packs: [])
        begin(edit.selections.isEmpty ? "正在恢复原卡图…" : "正在校验和安装异画…")
        worker.async { [weak self] in
            do {
                let result = try context.switcher.updateSkyStriker(target: context.target, selected: edit.selections,
                    pack: nil, scope: edit.scope, additionalPacks: makePacks(), source: source,
                    performanceOptOut: performanceOptOut)
                DispatchQueue.main.async { [weak self] in
                    if let self, let previous = queuedArtwork[key] {
                        let remaining = previous.filter { !edit.scope.contains($0.key) }
                        queuedArtwork[key] = remaining.isEmpty ? nil : remaining
                    }
                    let message = if result.installed > 0 {
                        "已安装 \(result.installed) 张异画。启动所选账号后可以在卡组编辑器查看。"
                    } else if result.preserved > 0 {
                        "已恢复原卡图。保留了 \(result.preserved) 个被游戏或其他 Mod 更新的文件。"
                    } else {
                        "已恢复所选账号的原卡图。"
                    }
                    self?.finish(message)
                    completed()
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.finish(message, failed: true) }
            }
        }
    }

    private func applyArtworkToAll(_ choices: [String: Int], performanceOptOut: Set<String>,
                                   makePacks: @escaping () throws -> [SkyStrikerPack],
                                   completed: @escaping () -> Void) {
        guard canApplyArtworkToAll, let installation, let source = artworkSource(for: installation) else { return }
        let switcher = Switcher(installation: installation, proDirectory: proDirectory)
        let accounts = accounts.map { account in
            let key = resourceKey(installation, account.id)
            return (key: key, name: aliases[String(account.id)] ?? account.displayName,
                    hasMapping: account.id == mainResourceAccount || resourceFolders[key] != nil,
                    target: artworkTarget(account.id, installation: installation, source: source))
        }
        let targets = accounts.compactMap(\.target)
        let edit = ArtworkEdit(choices: choices, packs: [])
        let selection = edit.selections
        begin("正在将卡图选择应用到所有账号…")
        worker.async { [weak self] in
            do {
                let outcomes = try switcher.updateSkyStriker(targets: targets, source: source, selected: selection,
                    pack: nil, scope: edit.scope, additionalPacks: makePacks(), performanceOptOut: performanceOptOut)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var pending = queuedArtwork
                    var applied = 0
                    var waiting = 0
                    var preserved = 0
                    var failures: [String] = []
                    for account in accounts {
                        var remaining = (pending[account.key] ?? [:]).filter { !edit.scope.contains($0.key) }
                        switch account.target.flatMap({ outcomes[$0] }) {
                        case .applied(let count)?:
                            applied += 1
                            preserved += count
                        case .failed(let reason)?:
                            failures.append("\(account.name)：\(reason)")
                        case nil where account.hasMapping:
                            failures.append("\(account.name)：资源目录关联有冲突。")
                        case .waitingForResources?, nil:
                            if !selection.isEmpty {
                                for (path, id) in choices {
                                    remaining[path] = QueuedArtworkChoice(artworkID: id,
                                        includePerformance: !performanceOptOut.contains(path))
                                }
                                waiting += 1
                            }
                        }
                        pending[account.key] = remaining.isEmpty ? nil : remaining
                    }
                    queuedArtwork = pending
                    var message = "已应用到 \(applied) 个账号。"
                    if waiting > 0 { message += "另有 \(waiting) 个账号将在准备好资源后应用。" }
                    if preserved > 0 { message += "保留了 \(preserved) 个被游戏或其他 Mod 更新的文件。" }
                    if !failures.isEmpty { message += failures.joined(separator: " ") }
                    finish(message, failed: !failures.isEmpty)
                    completed()
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.finish(message, failed: true) }
            }
        }
    }

    func setMainResourceAccount() {
        guard !busy, let installation, let account = selected,
              let reuse = Switcher(installation: installation).resources else { return }
        let bottle = installation.bottle.path
        let sourceKey = "resourceSource|\(bottle)"
        let existing = UserDefaults.standard.string(forKey: sourceKey)
        let secondary = Set(resourceFolders.compactMap { key, folder in
            key.hasPrefix(bottle + "|") && key != resourceKey(installation, account.id) ? folder : nil
        })
        begin("正在确认主账号的资源目录…")
        worker.async { [weak self] in
            do {
                let source: String
                if let existing, !secondary.contains(existing),
                   try reuse.accountDirectories().contains(existing) {
                    source = existing
                } else {
                    source = try reuse.findMainSource(excluding: secondary)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    UserDefaults.standard.set(source, forKey: sourceKey)
                    mainAccounts[bottle] = String(account.id)
                    UserDefaults.standard.set(mainAccounts, forKey: "resourceMainAccounts")
                    finish("已设定「\(account.displayName)」为资源主账号。")
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.finish(message, failed: true) }
            }
        }
    }

    private func resourceKey(_ installation: SteamInstallation, _ id: UInt64) -> String {
        "\(installation.bottle.path)|\(id)"
    }

    private func recordResourceDirectory(_ folder: String, for key: String) {
        guard resourceFolders[key] != folder else { return }
        resourceFolders[key] = folder
        UserDefaults.standard.set(resourceFolders, forKey: "resourceFolders")
    }

    func recover() {
        guard !busy, let installation else { return }
        let switcher = Switcher(installation: installation)
        begin("正在恢复 Steam 登录设置…")
        worker.async { [weak self] in
            do {
                try switcher.recover()
                DispatchQueue.main.async { [weak self] in self?.finish("Steam 登录设置已恢复。") }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.finish(message, failed: true) }
            }
        }
    }

    private func begin(_ message: String) {
        verifiedID = nil
        busy = true
        error = false
        status = message
    }

    private func finish(_ message: String, failed: Bool = false) {
        busy = false
        error = failed
        status = message
        refresh(updateStatus: false)
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let openSettings: () -> Void
    @FocusState private var editingAlias: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("账号切换").font(.title2.bold())
                Text(model.installation.map { "CrossOver · \($0.bottleName)" } ?? "Master Duel · CrossOver")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Steam 账号").font(.headline)
                    Text("\(model.accounts.count) 个").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.load) { Label("刷新", systemImage: "arrow.clockwise") }
                        .disabled(model.busy)
                }
                if model.accounts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 27))
                        Text("等待 Steam 账号")
                            .font(.headline)
                        if model.installation == nil {
                            Button("打开安装目录设置", action: openSettings)
                        } else {
                            Text("在 CrossOver 的 Steam 中登录并选择记住登录。")
                                .font(.subheadline)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.accounts) { account in accountRow(account) }
                        }
                        .padding(1)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .padding(22)
    }

    private func aliasEditor(_ account: SteamAccount) -> some View {
        HStack(spacing: 8) {
            TextField("昵称（留空则使用 Steam 昵称）", text: $model.alias)
                .textFieldStyle(.roundedBorder)
                .focused($editingAlias)
                .onAppear { editingAlias = true }
            Button("取消") { model.renameAccount = nil }.keyboardShortcut(.cancelAction)
            Button("保存") {
                model.rename(account, to: model.alias)
                model.renameAccount = nil
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func accountRow(_ account: SteamAccount) -> some View {
        let selected = model.selectedID == account.id
        let name = model.aliases[String(account.id)] ?? account.displayName
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button {
                    model.selectedID = account.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.body.weight(.medium)).lineLimit(1)
                            Text(account.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if model.mainResourceAccount == account.id {
                            Text("资源主账号").font(.caption).foregroundStyle(.secondary)
                        } else if model.verifiedID == account.id {
                            Text("本次登录已确认").font(.caption).foregroundStyle(.green)
                        } else if !account.remembered {
                            Text("需要先登录").font(.caption).foregroundStyle(.secondary)
                        } else if account.preferred {
                            Text("默认登录").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])

                Button {
                    model.alias = model.aliases[String(account.id)] ?? ""
                    model.renameAccount = account
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑 \(name) 的昵称")
                .help("编辑昵称")
            }
            if model.renameAccount?.id == account.id {
                aliasEditor(account)
            }
        }
        .disabled(model.busy)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.error ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundStyle(model.error ? .orange : .secondary)
                        .accessibilityHidden(true)
                }
                Text(model.status)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(model.status)
            }
            HStack {
                Menu("游戏资源") {
                    if model.mainResourceAccount == nil {
                        Button("将所选账号设为资源主账号") { model.setMainResourceAccount() }
                    } else if model.selectedID == model.mainResourceAccount {
                        Text("所选账号提供游戏资源")
                    } else if model.resourceTarget == nil {
                        Button("启动并识别新号目录") {
                            model.switchAccount(launchGame: true, identifyNewResources: true)
                        }
                    } else {
                        Button(model.canRestoreResources ? "修复资源索引" : "复用已下载资源") {
                            model.updateResources(restore: false)
                        }
                        Button("恢复新号原资源") { model.updateResources(restore: true) }
                            .disabled(!model.canRestoreResources)
                    }
                }
                .fixedSize()
                .disabled(model.busy || model.recoveryNeeded || model.selected?.remembered != true)
                Spacer()
                if model.recoveryNeeded {
                    Button("恢复登录设置", action: model.recover).disabled(model.busy)
                } else {
                    Button("仅切换 Steam") { model.switchAccount(launchGame: false) }
                        .disabled(model.busy || model.selected?.remembered != true)
                    Button("启动 MD") { model.switchAccount(launchGame: true) }
                        .help("Steam 已登录所选账号时直接启动，否则先切换账号。")
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.selected?.remembered != true)
                }
            }
        }
    }
}


struct SwitcherSettingsView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("安装目录") {
                        VStack(alignment: .leading, spacing: 14) {
                            row("Master Duel", directory: model.installation?.game, mdPro3: false)
                            Divider()
                            row("MDPro3", directory: model.proDirectory, mdPro3: true)
                            if let error = model.installationPathError {
                                Text(error).foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("启动游戏") {
                        Toggle("复用主账号语言", isOn: $model.reuseMainLanguage)
                            .disabled(model.mainResourceAccount == nil)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LoginItemView()
                }
                .padding(1)
            }
            .disabled(model.busy)
        }
        .padding(22)
    }

    private func row(_ label: String, directory: URL?, mdPro3: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.headline)
            Text(directory?.path ?? "尚未找到，请手动选择。")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("选择目录…") { model.chooseInstallationDirectory(mdPro3: mdPro3) }
                Button("恢复自动检测") { model.resetInstallationDirectory(mdPro3: mdPro3) }
            }
        }
    }
}

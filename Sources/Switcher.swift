import Foundation

enum SwitchProgress {
    case checking, stopping, configuring, waitingForLogin, launchingGame, locatingResources
    case initializingResources, preparingResources, refreshingDisplay
    case syncingGameLanguage, gameLanguageWarning(String), queuedArtworkApplied, artworkWarning(String)
    case applyingRoyalFinish, royalFinishApplied, royalFinishWarning(String)

    var title: String {
        switch self {
        case .checking: "正在检查 Steam 和游戏进程…"
        case .stopping: "正在正常退出 Steam…"
        case .configuring: "正在备份并更新 Steam 登录设置…"
        case .waitingForLogin: "正在确认 Steam 登录。若 Steam 要求验证，请在 Steam 中完成。"
        case .launchingGame: "已确认账号，正在启动 Master Duel…"
        case .locatingResources: "正在识别新号资源目录。到开始画面后退出游戏。"
        case .initializingResources: "首次启动，正在让游戏生成小号的资源目录…"
        case .refreshingDisplay: "检测到屏幕变化，正在刷新 CrossOver 会话…"
        case .preparingResources: "正在自动复用主账号的游戏资源…"
        case .syncingGameLanguage: "正在同步主账号的游戏语言…"
        case .gameLanguageWarning(let reason): reason
        case .queuedArtworkApplied: "已应用为此账号排队的闪刀卡图。"
        case .artworkWarning(let reason): reason
        case .applyingRoyalFinish: "正在为所选卡片加载动态镜碎…"
        case .royalFinishApplied: "动态镜碎已加载。"
        case .royalFinishWarning(let reason): reason
        }
    }
}

struct Switcher: Sendable {
    struct ResourceLaunch: Sendable {
        let source: String
        let target: String?
        let otherAccounts: Set<String>
    }

    enum ArtworkOutcome {
        case applied(preserved: Int), waitingForResources, failed(String)
    }

    let installation: SteamInstallation
    let client: any SteamClient
    let storage: URL
    let proDirectory: URL?

    init(installation: SteamInstallation, client: (any SteamClient)? = nil,
         storage: URL? = nil, proDirectory: URL? = nil) {
        self.installation = installation
        self.client = client ?? CrossOverClient(install: installation)
        self.proDirectory = proDirectory
        self.storage = storage ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MD Switcher")
    }

    var hasPendingRecovery: Bool { FileManager.default.fileExists(atPath: journalFile.path) }

    var resources: ResourceReuse? {
        installation.game.map { ResourceReuse(root: $0.appendingPathComponent("LocalData")) }
    }

    @discardableResult
    func changeAccount(to id: UInt64, launchGame: Bool, loginTimeout: TimeInterval = 120,
                       identifyNewResources: Bool = false,
                       resourceLaunch: ResourceLaunch? = nil,
                       syncMainLanguage: Bool = false,
                       queuedArtwork: ArtworkEdit? = nil,
                       knownResourceFolder: String? = nil,
                       royalFinish: Set<Int> = [],
                       recordResourceDirectory: (String) -> Void = { _ in },
                       report: (SwitchProgress) -> Void = { _ in }) throws -> String? {
        try withLock {
            guard !hasPendingRecovery else {
                throw SwitchError("有一次未完成的配置写入。请先恢复登录设置。")
            }

            // Validate the account before doing anything to a running Steam.
            _ = try LoginUsers(installation.readLoginFile()).selecting(id)
            report(.checking)
            var running = try client.processes()
            try requireGameClosed(running)
            if launchGame, try client.displayNeedsRefresh() {
                report(.refreshingDisplay)
                try refreshDisplaySession(running: running)
                running = try client.processes()
            }
            if launchGame, let folder = knownResourceFolder, let resources,
               (try? resources.accountDirectories().contains(folder)) == true {
                _ = try removeAddedSummonAnimations(in: resources, account: folder)
                try SkyStrikerMod(resources: resources, account: folder).requireSummonReady()
            }
            let activeAccount: () throws -> UInt64?
            if running.contains("steam.exe"), (try? client.activeAccount()) == id {
                activeAccount = { try client.activeAccount() }
            } else {
                let checkpoint = try restartSteam(for: id, running: running, loginTimeout: loginTimeout, report: report)
                activeAccount = { try checkpoint.activeAccount() }
            }
            guard launchGame else { return nil }
            if let resourceLaunch {
                let folder = try prepareForLaunch(resourceLaunch, account: id, activeAccount: activeAccount,
                                                  record: recordResourceDirectory, report: report)
                let resources = try resourceReuse()
                _ = try removeAddedSummonAnimations(in: resources, account: folder)
                try SkyStrikerMod(resources: resources, account: folder).requireSummonReady()
                if syncMainLanguage, let game = installation.game {
                    report(.syncingGameLanguage)
                    let check = {
                        try requireGameClosed(verifiedProcesses(account: id, activeAccount: activeAccount))
                    }
                    try check()
                    do {
                        let gameSettings = GameSettings(game: game, storage: storage)
                        try gameSettings.syncLanguage(from: resourceLaunch.source, to: folder, checkGameClosed: check)
                    } catch {
                        report(.gameLanguageWarning(error.localizedDescription))
                    }
                }
                if let queuedArtwork {
                    do {
                        _ = try SkyStrikerMod(resources: resourceReuse(), account: folder)
                            .update(queuedArtwork.selections, pack: nil, scope: queuedArtwork.scope,
                                    additionalPacks: queuedArtwork.packs) {
                                try requireGameClosed(verifiedProcesses(account: id, activeAccount: activeAccount))
                            }
                        report(.queuedArtworkApplied)
                    } catch {
                        report(.artworkWarning("异画尚未应用。\(error.localizedDescription)"))
                    }
                }
            }
            report(.launchingGame)
            try requireGameClosed(verifiedProcesses(account: id, activeAccount: activeAccount))
            let before = identifyNewResources ? try resourceReuse().accountDirectories() : nil
            try client.launchGame()
            try waitForGame()
            if before == nil, !royalFinish.isEmpty {
                report(.applyingRoyalFinish)
                do {
                    _ = try verifiedProcesses(account: id, activeAccount: activeAccount)
                    try client.activateRoyalFinish(royalFinish, storage: storage, expectedPID: nil)
                    report(.royalFinishApplied)
                } catch {
                    report(.royalFinishWarning("动态镜碎未加载。\(error.localizedDescription)"))
                }
            }
            guard let before else { return nil }
            report(.locatingResources)
            return try waitForResourceDirectory(since: before, account: id, activeAccount: activeAccount)
        }
    }

    // nil means Steam has not reported a verified account yet.
    func loadSteamRoyalFinish(pid: UInt32, selections: [String: [Int]]) throws -> Bool? {
        try withLock {
            guard !hasPendingRecovery, try client.processes().contains("masterduel.exe") else { return false }
            guard let account = try? client.activeAccount() else { return nil }
            let cards = Set(selections[String(account)] ?? []).filter(RoyalFinish.supports)
            guard !cards.isEmpty else { return false }
            try client.activateRoyalFinish(cards, storage: storage, expectedPID: pid)
            return true
        }
    }

    private func refreshDisplaySession(running: Set<String>) throws {
        let infrastructure: Set<String> = [
            "conhost.exe", "explorer.exe", "plugplay.exe", "rpcss.exe", "services.exe", "svchost.exe",
            "steam.exe", "steamservice.exe", "steamwebhelper.exe", "steamerrorreporter.exe",
            "steamerrorreporter64.exe", "tasklist.exe", "winedbg.exe", "winedevice.exe", "winewrapper.exe",
            "start.exe", "rundll32.exe", "wineboot.exe"
        ]
        func check(_ processes: Set<String>) throws {
            guard processes.isSubset(of: infrastructure) else {
                throw SwitchError("检测到屏幕变化。请先关闭这个 CrossOver 容器里的其他 Windows 程序，再启动游戏。")
            }
        }
        try check(running)
        if running.contains("steam.exe") {
            try client.stop()
            try waitForSteamExit()
        }
        try check(client.processes())
        try client.resetDisplaySession()
    }

    private func restartSteam(for id: UInt64, running: Set<String>, loginTimeout: TimeInterval,
                              report: (SwitchProgress) -> Void) throws -> LogCheckpoint {
        if running.contains("steam.exe") {
            report(.stopping)
            try client.stop()
            try waitForSteamExit()
        }

        report(.configuring)
        let original = try installation.readLoginFile()
        let users = try LoginUsers(original)
        let updated = try users.selecting(id)
        guard let account = users.accounts.first(where: { $0.id == id }) else {
            throw SwitchError("找不到所选账号，请刷新列表后重试。")
        }
        let previousUser = try client.autoLoginUser()
        let checkpoint = try LogCheckpoint(installation.logFile)
        try requireSteamAndGameClosed()
        let journal = Journal(bottlePath: installation.bottle.path, loginPath: installation.loginFile.path,
                              original: original, updated: updated,
                              previousUser: previousUser, selectedUser: account.username)
        try JSONEncoder().encode(journal).write(to: journalFile, options: [.atomic])
        do {
            guard try installation.readLoginFile() == original else {
                throw SwitchError("Steam 登录配置刚刚被其他程序修改。")
            }
            if previousUser != account.username { try client.setAutoLoginUser(account.username) }
            if updated != original { try updated.write(to: installation.loginFile, options: .atomic) }
            guard try installation.readLoginFile() == updated,
                  try client.autoLoginUser() == account.username else {
                throw SwitchError("Steam 登录配置写入后的核对失败。")
            }
            try requireSteamAndGameClosed()
            try client.start(username: account.username)
        } catch {
            let failure = error.localizedDescription
            do { try restore(journal) }
            catch {
                throw SwitchError("\(failure) 自动恢复未完成。请退出 Steam 后使用「恢复登录设置」。")
            }
            throw SwitchError("\(failure) 登录设置已恢复。")
        }
        try FileManager.default.removeItem(at: journalFile)

        report(.waitingForLogin)
        try waitForLogin(id, checkpoint: checkpoint, timeout: loginTimeout)
        return checkpoint
    }

    private func prepareForLaunch(_ plan: ResourceLaunch, account: UInt64, activeAccount: () throws -> UInt64?,
                                  record: (String) -> Void, report: (SwitchProgress) -> Void) throws -> String {
        let reuse = try resourceReuse()
        let reserved = plan.otherAccounts.union([plan.source])
        var target = plan.target
        if target == nil {
            target = try reuse.existingDirectory(for: account, excluding: reserved,
                                                 connectionLog: installation.logFile,
                                                 gameLog: installation.gameLog)
        }
        if target == nil {
            let before = try reuse.accountDirectories()
            try requireGameClosed(verifiedProcesses(account: account, activeAccount: activeAccount))
            report(.initializingResources)
            try client.launchGame()
            try waitForGame()
            let folder = try waitForResourceDirectory(since: before, account: account, activeAccount: activeAccount)
            target = folder
            record(folder)
            if try verifiedProcesses(account: account, activeAccount: activeAccount).contains("masterduel.exe") {
                try client.closeGame()
                let deadline = Date().addingTimeInterval(25)
                while try client.processes().contains("masterduel.exe") {
                    guard Date() < deadline else {
                        throw SwitchError("已识别小号目录。请正常退出游戏，再点「启动 MD」。")
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        } else if let target {
            record(target)
        }
        guard let target, !reserved.contains(target) else {
            throw SwitchError("小号资源目录与其他账号冲突，操作已停止。")
        }
        if try reuse.needsPreparation(target: target, source: plan.source) {
            report(.preparingResources)
            let mod = try SkyStrikerMod(resources: reuse, account: target)
            _ = try mod.update([:], pack: nil) {
                try requireGameClosed(verifiedProcesses(account: account, activeAccount: activeAccount))
            }
            _ = try reuse.prepare(target: target, source: plan.source) {
                try requireGameClosed(verifiedProcesses(account: account, activeAccount: activeAccount))
            }
        }
        return target
    }

    private func verifiedProcesses(account: UInt64, activeAccount: () throws -> UInt64?) throws -> Set<String> {
        let processes = try client.processes()
        guard processes.contains("steam.exe"), try activeAccount() == account else {
            throw SwitchError("Steam 登录状态已变化，操作已停止。")
        }
        return processes
    }

    private func waitForResourceDirectory(since before: Set<String>, account: UInt64,
                                          activeAccount: () throws -> UInt64?) throws -> String {
        let reuse = try resourceReuse()
        let deadline = Date().addingTimeInterval(45)
        repeat {
            guard try activeAccount() == account else {
                throw SwitchError("Steam 登录状态已变化，无法确认游戏资源目录。")
            }
            if let name = try reuse.newDirectory(since: before) { return name }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw SwitchError("没有检测到新建的资源目录。请在游戏中到达开始画面，再退出游戏重试。")
    }

    func prepareResources(target: String, source: String) throws -> ResourceReuse.Result {
        try withLock {
            let reuse = try resourceReuse()
            let check = { try requireGameClosed(client.processes()) }
            if try reuse.needsPreparation(target: target, source: source) {
                _ = try SkyStrikerMod(resources: reuse, account: target)
                    .update([:], pack: nil, checkGameClosed: check)
            }
            return try reuse.prepare(target: target, source: source, checkGameClosed: check)
        }
    }

    func restoreResources(target: String, source: String? = nil) throws {
        try withLock {
            let reuse = try resourceReuse()
            let check = { try requireGameClosed(client.processes()) }
            if let source {
                guard target != source, try reuse.accountDirectories().contains(source) else {
                    throw SwitchError("请选择资源目录已确认的小号。")
                }
                _ = try SkyStrikerMod(resources: reuse, account: target)
                    .update([:], pack: nil, checkGameClosed: check)
            }
            try reuse.restore(target: target, checkGameClosed: check)
        }
    }

    func updateSkyStriker(target: String, selected: [String: Int],
                          pack: SkyStrikerPack?, scope: Set<String>? = nil,
                          additionalPacks: [SkyStrikerPack] = []) throws -> SkyStrikerMod.Result {
        try withLock {
            guard !hasPendingRecovery else { throw SwitchError("请先恢复 Steam 登录设置。") }
            let mod = try SkyStrikerMod(resources: resourceReuse(), account: target)
            return try mod.update(selected, pack: pack, scope: scope, additionalPacks: additionalPacks) {
                try requireGameClosed(client.processes())
            }
        }
    }

    func updateSummonAnimation(target: String, selected: Set<SummonAnimation>) throws -> SkyStrikerMod.Result {
        try withLock {
            guard !hasPendingRecovery else { throw SwitchError("请先恢复 Steam 登录设置。") }
            let resources = try resourceReuse()
            let mod = try SkyStrikerMod(resources: resources, account: target)
            return try replaceSummonAnimations(selected, in: resources, account: target, mod: mod)
        }
    }

    func removeAddedSummonAnimations() throws -> Int {
        try withLock {
            let resources = try resourceReuse()
            var count = 0
            for account in try resources.accountDirectories().sorted() {
                if try removeAddedSummonAnimations(in: resources, account: account) { count += 1 }
            }
            return count
        }
    }

    private func removeAddedSummonAnimations(in resources: ResourceReuse, account: String) throws -> Bool {
        let mod = try SkyStrikerMod(resources: resources, account: account)
        guard try mod.hasAddedSummonTriggers() else { return false }
        _ = try replaceSummonAnimations(mod.summonSelections(), in: resources, account: account, mod: mod)
        return true
    }

    private func replaceSummonAnimations(_ selected: Set<SummonAnimation>, in resources: ResourceReuse,
                                         account: String, mod: SkyStrikerMod) throws -> SkyStrikerMod.Result {
        let check = { try requireGameClosed(client.processes()) }
        try check()
        let scope = try SummonAnimation.scope.union(mod.addedSummonFiles())
        if selected.isEmpty { return try mod.update([:], pack: nil, scope: scope, checkGameClosed: check) }
        guard selected.isSubset(of: Set(SummonAnimation.all)) else {
            throw SwitchError("当前仅支持替换原有的召唤演出。")
        }
        guard Set(selected.map(\.cid)).count == selected.count else {
            throw SwitchError("每张卡只能选择一款召唤动画。")
        }

        let usesTemplate = selected.contains { $0.donor == nil }
        let existing = Set(selected.flatMap(\.paths)).union([SummonAnimation.catalogPath])
        var originals: [String: Data] = [:]
        let inputs = existing.union(usesTemplate ? SummonAnimation.kagari.paths : [])
        for path in inputs { originals[path] = try resources.originalArtwork(account: account, path: path) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("md-summon-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work) }
        let engine = CardSearchEngine(storage: storage, proDirectory: proDirectory)
        let pack = try engine.makeSummonPack(cache: resources.artworkCache(account: account),
                                             originals: originals, selected: selected, work: work)
        var files: [String: Int] = [:]
        var added: Set<String> = []
        for card in pack.cards {
            guard card.variants.count == 1, let variant = card.variants.first,
                  files.updateValue(variant.id, forKey: card.path) == nil,
                  (card.originalSHA256 != nil) == existing.contains(card.path) else {
                throw SwitchError("召唤动画包格式异常。")
            }
            if card.originalSHA256 == nil { added.insert(card.path) }
        }
        guard Set(files.keys).isSuperset(of: existing), usesTemplate || added.isEmpty else {
            throw SwitchError("召唤动画包缺少资源或范围不匹配。")
        }
        return try mod.update(files, pack: pack, scope: scope.union(added), newSummonPaths: added,
                              summonChoices: Set(selected.map(\.id)), checkGameClosed: check)
    }
    func updateSkyStriker(targets: [String], source: String, selected: [String: Int],
                          pack: SkyStrikerPack?, scope: Set<String>? = nil,
                          additionalPacks: [SkyStrikerPack] = []) throws -> [String: ArtworkOutcome] {
        try withLock {
            guard !hasPendingRecovery else { throw SwitchError("请先恢复 Steam 登录设置。") }
            let check = { try requireGameClosed(client.processes()) }
            try check()
            let reuse = try resourceReuse()
            let known = try reuse.accountDirectories()
            guard known.contains(source) else { throw SwitchError("找不到主账号资源目录。") }
            var outcomes: [String: ArtworkOutcome] = [:]
            for target in targets {
                do {
                    guard known.contains(target) else {
                        outcomes[target] = .waitingForResources
                        continue
                    }
                    if !selected.isEmpty, target != source, try reuse.needsPreparation(target: target, source: source) {
                        outcomes[target] = .waitingForResources
                        continue
                    }
                    let result = try SkyStrikerMod(resources: reuse, account: target)
                        .update(selected, pack: pack, scope: scope, additionalPacks: additionalPacks, checkGameClosed: check)
                    outcomes[target] = .applied(preserved: result.preserved)
                } catch {
                    outcomes[target] = .failed(error.localizedDescription)
                }
            }
            return outcomes
        }
    }

    private func resourceReuse() throws -> ResourceReuse {
        guard let resources else { throw SwitchError("找不到 Master Duel 游戏目录。") }
        return resources
    }

    func recover() throws {
        try withLock {
            guard hasPendingRecovery else { return }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalFile))
            try restore(journal)
        }
    }

    private struct Journal: Codable {
        let bottlePath: String
        let loginPath: String
        let original: Data
        let updated: Data
        let previousUser: String?
        let selectedUser: String
    }

    private var journalFile: URL { storage.appendingPathComponent("pending-switch.json") }

    private func restore(_ journal: Journal) throws {
        guard journal.bottlePath == installation.bottle.path,
              journal.loginPath == installation.loginFile.path else {
            throw SwitchError("恢复记录对应另一套 Steam 安装。")
        }
        try requireSteamAndGameClosed()
        let vdf = try installation.readLoginFile()
        let user = try client.autoLoginUser()
        guard vdf == journal.original || vdf == journal.updated,
              user == journal.previousUser || user == journal.selectedUser else {
            throw SwitchError("Steam 登录设置已被其他程序修改。恢复记录保留在工具的支持文件夹中。")
        }
        if vdf != journal.original { try journal.original.write(to: installation.loginFile, options: .atomic) }
        if user != journal.previousUser { try client.setAutoLoginUser(journal.previousUser) }
        guard try installation.readLoginFile() == journal.original,
              try client.autoLoginUser() == journal.previousUser else {
            throw SwitchError("恢复后的 Steam 登录配置核对失败。")
        }
        try FileManager.default.removeItem(at: journalFile)
    }

    private func withLock<Result>(_ operation: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = storage.appendingPathComponent("switch.lock").path
        let descriptor = open(file, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SwitchError("无法打开换号锁。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SwitchError("另一个换号操作正在运行。")
        }
        return try operation()
    }

    private func requireGameClosed(_ processes: Set<String>) throws {
        if processes.contains("masterduel.exe") {
            throw SwitchError("Master Duel 正在运行。请先正常退出游戏。")
        }
    }

    private func requireSteamAndGameClosed() throws {
        let processes = try client.processes()
        try requireGameClosed(processes)
        guard !processes.contains("steam.exe") else {
            throw SwitchError("Steam 正在运行。请先正常退出 Steam。")
        }
    }

    private func waitForSteamExit() throws {
        let deadline = Date().addingTimeInterval(35)
        repeat {
            let processes = try client.processes()
            try requireGameClosed(processes)
            // CrossOver can keep detached browser helpers after Steam itself shuts down.
            if !processes.contains("steam.exe") { return }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw SwitchError("Steam 没有正常退出。请在 Steam 中退出后重试。")
    }

    private func waitForLogin(_ id: UInt64, checkpoint: LogCheckpoint, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let active = try checkpoint.activeAccount() {
                guard active == id else {
                    throw SwitchError("Steam 登录了另一个账号。请核对 Steam 中的账号后重试。")
                }
                if try client.processes().contains("steam.exe"), try checkpoint.activeAccount() == id {
                    return
                }
            }
            Thread.sleep(forTimeInterval: min(1, max(0, deadline.timeIntervalSinceNow)))
        } while Date() < deadline
        throw SwitchError("等待 Steam 登录超时。请检查 Steam 是否需要密码、Steam Guard 或网络连接。")
    }

    private func waitForGame() throws {
        let deadline = Date().addingTimeInterval(40)
        repeat {
            if try client.processes().contains("masterduel.exe") { return }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        throw SwitchError("Steam 已收到启动请求。请在 Steam 中查看游戏的启动或更新状态。")
    }
}

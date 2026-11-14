import CryptoKit
import Foundation

@main
enum CoreChecks {
    private static let firstID = SteamAccount.individualBase + 101
    private static let secondID = SteamAccount.individualBase + 202
    private static let fixture = """
    "users"
    {
        "\(firstID)"
        {
            "AccountName" "first"
            "PersonaName" "大号 🐉"
            "AutoLogin" "1"
            "RememberPassword" "1"
            "Custom" { "Leave" "untouched" }
        }
        "\(secondID)"
        {
            "AccountName" "second"
            "PersonaName" "小号"
            "AutoLogin" "0"
            "RememberPassword" "1"
        }
    }
    """

    static func main() throws {
        try installationPaths()
        try preferences()
        try authentication()
        try resourceReuse()
        try skyStrikerMod()
        try overFrameArtwork()
        try artworkCollections()
        try artworkCache()
        try run("successful switch and launch") { switcher, client in
            try switcher.changeAccount(to: secondID, launchGame: true)
            try expect(client.events == ["registry:second", "start", "game"])
            let accounts = try LoginUsers(switcher.installation.readLoginFile()).accounts
            try expect(accounts.filter(\.preferred).map(\.id) == [secondID])
        }
        try run("graceful Steam restart") { switcher, client in
            client.active = ["steam.exe", "steamwebhelper.exe"]
            try switcher.changeAccount(to: secondID, launchGame: false)
            try expect(client.events == ["stop", "registry:second", "start"])
        }
        try run("launch with the Steam account already signed in") { switcher, client in
            client.active = ["steam.exe"]
            client.onActiveAccount = { secondID }
            try switcher.changeAccount(to: secondID, launchGame: true)
            try expect(client.events == ["game"])
            try expect(try switcher.installation.readLoginFile() == Data(fixture.utf8))
        }
        try run("dynamic Royal Finish activates only after the selected game launch") { switcher, client in
            client.active = ["steam.exe"]
            client.onActiveAccount = { secondID }
            try switcher.changeAccount(to: secondID, launchGame: true, royalFinish: [13668, 13670])
            try expect(client.events == ["game", "royal:[13668, 13670]"])
            let mask = try RoyalFinish.selectionFile([13668, 13670])
            try expect(mask.count == 8192 && mask[13668 / 8] == 0x50)
        }
        try run("Steam launches load Royal Finish once for the verified account") { switcher, client in
            let monitor = SteamRoyalFinishMonitor()
            let selections = [String(firstID): [13670], String(secondID): [17069]]
            let first = #"[2026-11-11 12:00:00] AppID 1449850 adding PID 1600 as a tracked process ""C:\Games\masterduel.exe""#
            let child = #"[2026-11-11 12:00:00] AppID 1449850 adding PID 1700 as a tracked process ""C:\Games\UnityCrashHandler64.exe""#
            let other = #"[2026-11-11 12:00:01] AppID 400 adding PID 1800 as a tracked process ""C:\Games\masterduel.exe""#
            let stop = "[2026-11-11 12:00:02] AppID 1449850 no longer tracking PID 1600, exit code 0"
            let relaunch = first.replacingOccurrences(of: "12:00:00", with: "12:00:03")
                .replacingOccurrences(of: "PID 1600", with: "PID 1900")
            func write(_ rows: [String]) throws {
                try Data((rows.joined(separator: "\r\n") + "\r\n").utf8).write(to: switcher.installation.gameLog)
            }
            try write([other])
            try expect(try !monitor.poll(switcher: switcher, selections: selections))
            try write([first, child, other])
            client.active = ["steam.exe", "masterduel.exe"]
            try expect(try !monitor.poll(switcher: switcher, selections: selections))
            client.onActiveAccount = { secondID }
            try expect(try monitor.poll(switcher: switcher, selections: selections))
            try expect(try !monitor.poll(switcher: switcher, selections: selections))
            try write([first, stop, relaunch])
            client.onActiveAccount = { firstID }
            try expect(try monitor.poll(switcher: switcher, selections: selections))
            try expect(client.events == ["royal:[17069]", "royal:[13670]"])
            try expect(client.royalPIDs == [1600, 1900])
        }
        try run("refresh the CrossOver session only when the display changed") { switcher, client in
            client.active = ["steam.exe", "explorer.exe"]
            client.staleDisplay = true
            client.onActiveAccount = { secondID }
            try switcher.changeAccount(to: secondID, launchGame: true)
            try expect(client.events == ["stop", "display-refresh", "registry:second", "start", "game"])
        }
        try run("account changes before direct launch") { switcher, client in
            client.active = ["steam.exe"]
            var accounts = [firstID, secondID]
            client.onActiveAccount = { accounts.removeFirst() }
            try expectError("Steam 登录状态已变化") {
                try switcher.changeAccount(to: firstID, launchGame: true)
            }
            try expect(client.events.isEmpty)
        }
        try run("refuse to close a running game") { switcher, client in
            client.active = ["steam.exe", "masterduel.exe"]
            try expectError("Master Duel 正在运行") {
                try switcher.changeAccount(to: secondID, launchGame: true)
            }
            try expect(client.events.isEmpty)
            let config = try switcher.installation.readLoginFile()
            try expect(config == Data(fixture.utf8))
        }
        try run("wrong account blocks game") { switcher, client in
            client.loginID = firstID
            try expectError("登录了另一个账号") {
                try switcher.changeAccount(to: secondID, launchGame: true)
            }
            try expect(!client.events.contains("game"))
        }
        try run("historical login cannot launch game") { switcher, client in
            try log(secondID).write(to: switcher.installation.logFile, atomically: true, encoding: .utf8)
            client.loginID = nil
            try expectError("等待 Steam 登录超时") {
                try switcher.changeAccount(to: secondID, launchGame: true, loginTimeout: 0)
            }
            try expect(!client.events.contains("game"))
        }
        try run("rollback after configuration write") { switcher, client in
            client.failStart = true
            try expectError("登录设置已恢复") {
                try switcher.changeAccount(to: secondID, launchGame: true)
            }
            let config = try switcher.installation.readLoginFile()
            try expect(config == Data(fixture.utf8))
            try expect(client.username == "first")
        }
        try run("recover after an interrupted rollback") { switcher, client in
            client.failStart = true
            client.refuseRestore = true
            try expectError("自动恢复未完成") {
                try switcher.changeAccount(to: secondID, launchGame: false)
            }
            try expect(switcher.hasPendingRecovery)
            try expectError("未完成的配置写入") {
                try switcher.changeAccount(to: firstID, launchGame: false)
            }
            client.refuseRestore = false
            try switcher.recover()
            try expect(client.username == "first")
        }
        try run("pending recovery does not overwrite independent changes") { switcher, client in
            client.failStart = true
            client.refuseRestore = true
            try expectError("自动恢复未完成") {
                try switcher.changeAccount(to: secondID, launchGame: false)
            }
            let changed = Data((fixture + "\n// changed outside the tool\n").utf8)
            try changed.write(to: switcher.installation.loginFile, options: .atomic)
            client.refuseRestore = false
            try expectError("已被其他程序修改") { try switcher.recover() }
            let config = try switcher.installation.readLoginFile()
            try expect(config == changed && switcher.hasPendingRecovery)
        }
    }

    private static func skyStrikerMod() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent("LocalData")
        let source = root.appendingPathComponent("aaaa1111")
        let target = root.appendingPathComponent("bbbb2222")
        let packFolder = folder.appendingPathComponent("pack")
        let relative = "ab/ab123456"
        let originalURL = source.appendingPathComponent("0000/\(relative)")
        let liveURL = target.appendingPathComponent("0000/\(relative)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        for directory in [originalURL.deletingLastPathComponent(), liveURL.deletingLastPathComponent(), packFolder] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let original = Data("original art".utf8)
        let first = Data("UnityFS\0first art".utf8)
        let second = Data("UnityFS\0second art".utf8)
        let independent = Data("game update".utf8)
        try original.write(to: originalURL)
        try original.write(to: liveURL)
        try first.write(to: packFolder.appendingPathComponent("1.bundle"))
        try second.write(to: packFolder.appendingPathComponent("2.bundle"))
        func sha(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = """
        [{"name":"Test","path":"\(relative)","originalSHA256":"\(sha(original))",
          "variants":[{"id":1,"sha256":"\(sha(first))"},{"id":2,"sha256":"\(sha(second))"}]}]
        """
        try Data(manifest.utf8).write(to: packFolder.appendingPathComponent("manifest.json"))
        let pack = try SkyStrikerPack(directory: packFolder)
        let reuse = ResourceReuse(root: root)
        try expectError("账号") { _ = try SkyStrikerMod(resources: reuse, account: "cccc3333") }
        let mod = try SkyStrikerMod(resources: reuse, account: "bbbb2222")
        try expectError("game open") {
            _ = try mod.update([relative: 1], pack: pack) { throw SwitchError("game open") }
        }
        try expect(try Data(contentsOf: liveURL) == original)
        _ = try mod.update([relative: 1], pack: pack) {}
        try expect(try Data(contentsOf: liveURL) == first)
        _ = try mod.update([relative: 2], pack: pack) {}
        try expect(try Data(contentsOf: liveURL) == second)
        try expect(try mod.selections() == [relative: 2])
        _ = try mod.update([:], pack: nil) {}
        try expect(try Data(contentsOf: liveURL) == original)
        try expect(try Data(contentsOf: originalURL) == original)
        _ = try mod.update([relative: 1], pack: pack) {}
        try independent.write(to: liveURL, options: .atomic)
        let restored = try mod.update([:], pack: nil) {}
        try expect(restored.preserved == 1)
        try expect(try Data(contentsOf: liveURL) == independent)
        try expect(try mod.selections().isEmpty)
        try expectError("版本") { _ = try mod.update([relative: 1], pack: pack) {} }

        let mainMod = try SkyStrikerMod(resources: reuse, account: "aaaa1111")
        let mainIndex = source.appendingPathComponent("0000/86/868ffd0e")
        let fresh = root.appendingPathComponent("cccc3333/0000")
        let freshIndex = fresh.appendingPathComponent("86/868ffd0e")
        let freshArt = fresh.appendingPathComponent(relative)
        for file in [mainIndex, freshIndex] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let emptyIndex = Data(#"{"informations":[]}"#.utf8)
        let officialIndex = Data("""
        {"informations":[{"assetName":"\(relative)","version":"1","bytes":\(original.count),"crc":"\(sha(original))"}]}
        """.utf8)
        try officialIndex.write(to: mainIndex)
        try emptyIndex.write(to: freshIndex)
        _ = try mainMod.update([relative: 2], pack: pack) {}
        try expect(try Data(contentsOf: originalURL) == second)
        try expect(try reuse.prepare(target: "cccc3333", source: "aaaa1111") {}.clonedFiles == 1)
        try expect(try Data(contentsOf: freshArt) == original)
        try expect(try Data(contentsOf: freshIndex) == officialIndex)
        try emptyIndex.write(to: freshIndex, options: .atomic)
        try expect(try reuse.prepare(target: "cccc3333", source: "aaaa1111") {}.clonedFiles == 0)
        try expect(try Data(contentsOf: originalURL) == second)
        try expect(try Data(contentsOf: liveURL) == independent)
        _ = try mainMod.update([:], pack: nil) {}
        try expect(try Data(contentsOf: originalURL) == original)
        print("PASS independent main account artwork and clean resource reuse and index repair")

        let deferred = root.appendingPathComponent("dddd4444/0000")
        let deferredArt = deferred.appendingPathComponent(relative)
        let installation = SteamInstallation(wine: folder, bottle: folder, steam: folder, game: folder)
        for path in [deferred, installation.loginFile.deletingLastPathComponent(),
                     installation.logFile.deletingLastPathComponent()] {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data(fixture.utf8).write(to: installation.loginFile)
        let client = FakeClient(logFile: installation.logFile)
        let switcher = Switcher(installation: installation, client: client, storage: folder.appendingPathComponent("support"))
        let targets = ["aaaa1111", "cccc3333", "dddd4444"]
        let selection = [relative: 1]
        let outcomes = try switcher.updateSkyStriker(targets: targets, source: "aaaa1111", selected: selection, pack: pack)
        guard case .applied? = outcomes["aaaa1111"], case .applied? = outcomes["cccc3333"],
              case .waitingForResources? = outcomes["dddd4444"] else {
            throw SwitchError("Unexpected artwork batch results.")
        }
        try expect(try Data(contentsOf: originalURL) == first && Data(contentsOf: freshArt) == first)
        try expect(!fm.fileExists(atPath: deferredArt.path))
        var queuedApplied = false
        client.onGameLaunch = { try expect(try Data(contentsOf: deferredArt) == first) }
        try switcher.changeAccount(to: secondID, launchGame: true,
            resourceLaunch: .init(source: "aaaa1111", target: "dddd4444", otherAccounts: ["cccc3333"]),
            queuedArtwork: ArtworkEdit(choices: selection, packs: [pack]), report: { progress in
                if case .queuedArtworkApplied = progress { queuedApplied = true }
            })
        try expect(queuedApplied)
        try expectError("Master Duel 正在运行") {
            _ = try switcher.updateSkyStriker(targets: targets, source: "aaaa1111", selected: [:], pack: nil)
        }
        client.active.remove("masterduel.exe")
        _ = try switcher.updateSkyStriker(targets: targets, source: "aaaa1111", selected: [:], pack: nil)
        for file in [originalURL, freshArt, deferredArt] { try expect(try Data(contentsOf: file) == original) }
        print("PASS batch artwork, deferred application before launch, and batch restoration")

        let extra = "cd/cd123456"
        let extraURL = source.appendingPathComponent("0000/\(extra)")
        let extraPackFolder = folder.appendingPathComponent("extra-pack")
        for directory in [extraURL.deletingLastPathComponent(), extraPackFolder] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try original.write(to: extraURL)
        try second.write(to: extraPackFolder.appendingPathComponent("3.bundle"))
        let extraManifest = """
        [{"name":"Other Card","path":"\(extra)","originalSHA256":"\(sha(original))",
          "variants":[{"id":3,"sha256":"\(sha(second))"}]}]
        """
        try Data(extraManifest.utf8).write(to: extraPackFolder.appendingPathComponent("manifest.json"))
        let extraPack = try SkyStrikerPack(directory: extraPackFolder)
        _ = try switcher.updateSkyStriker(target: "aaaa1111", selected: [relative: 1, extra: 3],
                                         pack: nil, scope: [relative, extra], additionalPacks: [pack, extraPack])
        try expect(try mainMod.selections() == [relative: 1, extra: 3])
        try expect(try Data(contentsOf: extraURL) == second)
        _ = try mainMod.update([:], pack: nil, scope: [extra]) {}
        try expect(try Data(contentsOf: extraURL) == original)
        try expect(try mainMod.selections() == selection)
        try expect(try Data(contentsOf: originalURL) == first)
        _ = try mainMod.update([:], pack: nil, scope: [relative]) {}
        try expect(try mainMod.selections().isEmpty)
        try expect(try Data(contentsOf: originalURL) == original)
        print("PASS applying multiple artwork packs together and restoring only the selected scope")

        let dependencyCatalog = source.appendingPathComponent("0000/\(SummonAnimation.catalogPath)")
        try fm.createDirectory(at: dependencyCatalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalCatalog = Data(repeating: 17, count: 4 * 1024 * 1024 + 1)
        let changedCatalog = Data(repeating: 19, count: originalCatalog.count)
        try changedCatalog.write(to: dependencyCatalog)
        let interrupted: [String: Any] = [
            "pendingSummonAnimation": true, "selections": [String: Int](),
            "files": [SummonAnimation.catalogPath: [
                "original": originalCatalog.base64EncodedString(), "replacements": [sha(changedCatalog)]
            ]],
        ]
        let journal = source.appendingPathComponent(".md-switcher-sky-striker.json")
        try JSONSerialization.data(withJSONObject: interrupted).write(to: journal)
        let previousEvents = client.events
        try expectError("有未完成的演出写入") {
            try switcher.changeAccount(to: firstID, launchGame: true, knownResourceFolder: "aaaa1111")
        }
        try expect(client.events == previousEvents)
        _ = try switcher.updateSummonAnimation(target: "aaaa1111", selected: [])
        try mainMod.requireSummonReady()
        try expect(try Data(contentsOf: dependencyCatalog) == originalCatalog)
        try expect(!fm.fileExists(atPath: journal.path))
        print("PASS blocking launch after interrupted summon edits and restoring the dependency catalog")

        let addedPath = "73/73c6165c"
        let retiredArtworkID = 26077389
        let addedURL = source.appendingPathComponent("0000/\(addedPath)")
        let summonPack = folder.appendingPathComponent("summon-pack")
        try fm.createDirectory(at: summonPack, withIntermediateDirectories: false)
        try first.write(to: summonPack.appendingPathComponent("123.bundle"))
        let summonManifest = """
        [{"name":"New cut-in","path":"\(addedPath)","originalSHA256":null,
          "variants":[{"id":123,"sha256":"\(sha(first))"}]}]
        """
        try Data(summonManifest.utf8).write(to: summonPack.appendingPathComponent("manifest.json"))
        let animationPack = try SkyStrikerPack(directory: summonPack)
        _ = try mainMod.update([addedPath: 123], pack: animationPack,
                               scope: [addedPath, SummonAnimation.catalogPath], newSummonPaths: [addedPath],
                               summonChoices: [retiredArtworkID]) {}
        try expect(try Data(contentsOf: addedURL) == first)
        try expect(try mainMod.summonSelections().isEmpty)
        try expect(try mainMod.addedSummonFiles() == [addedPath])
        let newAccount = root.appendingPathComponent("eeee5555/0000")
        try fm.createDirectory(at: newAccount.appendingPathComponent("86"), withIntermediateDirectories: true)
        try emptyIndex.write(to: newAccount.appendingPathComponent("86/868ffd0e"))
        _ = try reuse.prepare(target: "eeee5555", source: "aaaa1111") {}
        try expect(!fm.fileExists(atPath: newAccount.appendingPathComponent(addedPath).path))
        let trigger = source.appendingPathComponent("0000/\(SummonAnimation.gatePath)")
        try fm.createDirectory(at: trigger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try first.write(to: trigger)
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
        var files = legacy["files"] as! [String: Any]
        files[SummonAnimation.gatePath] = ["original": original.base64EncodedString(), "replacements": [sha(first)]]
        legacy["files"] = files
        try JSONSerialization.data(withJSONObject: legacy).write(to: journal)
        try expect(try switcher.removeLegacySummonAnimations() == 1)
        try expect(try Data(contentsOf: trigger) == original)
        try expect(!fm.fileExists(atPath: addedURL.path))
        try expect(try mainMod.summonSelections().isEmpty)
        try expect(try switcher.removeLegacySummonAnimations() == 0)
        print("PASS removing legacy added cut-ins and restoring triggers without copying assets to other accounts")
    }

    private static func overFrameArtwork() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let resources = ResourceReuse(root: directory.appendingPathComponent("LocalData"))
        let cache = resources.root.appendingPathComponent("aaaa1111/0000")
        let packs = directory.appendingPathComponent("packs")
        let gate = "99/99f84cce"
        let first = "19/1991748e"
        let second = "1a/1a57fc76"
        let originals = [first: Data("first art".utf8), second: Data("second art".utf8),
                         gate: Data("official gate".utf8)]
        let square = Data("UnityFS\0square".utf8)
        let tall = Data("UnityFS\0tall".utf8)
        func write(_ data: Data, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for (path, data) in originals {
            try write(data, to: cache.appendingPathComponent(path))
        }
        let entries: [[String: Any]] = originals.map { path, data in
            ["assetName": path, "version": "1", "bytes": data.count, "crc": artworkDigest(data)]
        }
        try write(JSONSerialization.data(withJSONObject: ["informations": entries]),
                  to: cache.appendingPathComponent(ResourceReuse.indexPath))
        func pack(tallArt: Bool) throws -> SkyStrikerPack {
            let destination = packs.appendingPathComponent(tallArt ? "tall" : "square")
            let image = tallArt ? tall : square
            var cards: [[String: Any]] = []
            for (path, cid, id) in [(first, 17034, 10), (second, 17069, 20)] {
                var row: [String: Any] = [
                    "name": "Test", "path": path, "originalSHA256": artworkDigest(originals[path]!),
                    "variants": [["id": id, "sha256": artworkDigest(image)]]
                ]
                if tallArt { row["overFrame"] = ["gate": gate, "cardID": cid] }
                cards.append(row)
                try write(image, to: destination.appendingPathComponent("\(id).bundle"))
            }
            try write(JSONSerialization.data(withJSONObject: cards), to: destination.appendingPathComponent("manifest.json"))
            return try SkyStrikerPack(directory: destination)
        }
        func registration(_ original: Data, _ ids: Set<Int>) throws -> Data {
            try expect(original == originals[gate])
            return original + Data(ids.sorted().map(String.init).joined(separator: ",").utf8)
        }
        let account = try SkyStrikerMod(resources: resources, account: "aaaa1111")
        _ = try account.update([first: 10], pack: pack(tallArt: false), scope: [first]) {}
        _ = try account.update([first: 10, second: 20], pack: pack(tallArt: true), scope: [first, second],
                               editOverFrameGate: registration) {}
        try expect(try Data(contentsOf: cache.appendingPathComponent(first)) == tall)
        try expect(try Data(contentsOf: cache.appendingPathComponent(gate)) == registration(originals[gate]!, [17034, 17069]))

        let target = resources.root.appendingPathComponent("bbbb2222/0000")
        try write(Data(#"{"informations":[]}"#.utf8), to: target.appendingPathComponent(ResourceReuse.indexPath))
        _ = try resources.prepare(target: "bbbb2222", source: "aaaa1111") {}
        for (path, data) in originals { try expect(try Data(contentsOf: target.appendingPathComponent(path)) == data) }

        _ = try account.update([:], pack: nil, scope: [first], editOverFrameGate: registration) {}
        try expect(try Data(contentsOf: cache.appendingPathComponent(first)) == originals[first])
        try expect(try Data(contentsOf: cache.appendingPathComponent(second)) == tall)
        try expect(try Data(contentsOf: cache.appendingPathComponent(gate)) == registration(originals[gate]!, [17069]))
        _ = try account.update([:], pack: nil) {}
        for (path, data) in originals { try expect(try Data(contentsOf: cache.appendingPathComponent(path)) == data) }
        try expect(try account.selections().isEmpty)
        print("PASS over-frame upgrade, isolated resource reuse, and scoped restoration")
    }

    private static func artworkCollections() throws {
        let variant = SearchCard.Variant(id: 68468460, file: "68468460.jpg")
        let albaz = SearchCard(id: "albaz", cid: 15245, masterName: "阿尔白斯之落胤",
                               proName: "阿不思的落胤", codes: [68468459], masterIDs: [], variants: [variant],
                               path: "ab/ab123456", series: ["烙印"], originalPreviewPath: "Art/68468459.jpg")
        let aluber = SearchCard(id: "aluber", cid: 16195, masterName: "死狱乡的导化 阿鲁伯",
                                proName: nil, codes: [], masterIDs: [], variants: [], path: nil, series: ["烙印"])
        let titleOnly = SearchCard(id: "title", cid: 99, masterName: "烙印测试卡", proName: nil,
                                   codes: [], masterIDs: [], variants: [], path: nil, series: nil)
        let catalog = CardSearchCatalog(cards: [aluber, albaz, titleOnly],
                                        artDirectory: FileManager.default.temporaryDirectory)
        try expect(catalog.results(for: "烙印系列").series.map(\.id) == ["albaz", "aluber"])
        try expect(catalog.results(for: "烙印").names.map(\.id) == ["title"])
        try expect(catalog.results(for: "烙印", onlyArtwork: true).cards.map(\.id) == ["albaz"])
        try expect(catalog.results(for: "阿不思").cards.map(\.id) == ["albaz"])
        try expect(catalog.artworkPreview(for: albaz, variant: nil)?.lastPathComponent == "68468459.jpg")
        try expect(catalog.artworkPreview(for: albaz, variant: variant)?.lastPathComponent == variant.file)
        var missingOriginal = albaz
        missingOriginal.originalPreviewPath = nil
        missingOriginal.previewFile = variant.file
        try expect(catalog.artworkPreview(for: missingOriginal, variant: nil) == nil)

        let domain = "local.md-switcher.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw SwitchError("Cannot create test defaults.") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let custom = ArtworkCollection(id: "custom", name: "收藏", choices: [15245: variant.id, 16195: ArtworkCollection.cardOnly])
        var preset = ArtworkCollection.presets[1]
        preset.choices.removeValue(forKey: 15245)
        ArtworkCollection.save([preset, custom], to: defaults)
        try expect(ArtworkCollection.load(from: defaults).map(\.name) == ["闪刀姬", "烙印", "黑魔导", "收藏"])
        try expect(ArtworkCollection.load(from: defaults)[1] == preset)
        try expect(ArtworkCollection.load(from: defaults).last?.cards(in: catalog).first?.variant?.id == variant.id)
        let members = ArtworkCollection.load(from: defaults).last?.cards(in: catalog) ?? []
        try expect(members.filter(\.hasArtworkChoice).map(\.id) == [15245])
        try expect(Set(members.compactMap(\.card).flatMap(\.royalCardIDs)) == [15245, 16195])
        print("PASS series search, alternate card names, artwork filtering, and collection persistence")
    }

    private static func artworkCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let art = folder.appendingPathComponent("Picture/Art")
        let cache = folder.appendingPathComponent("card-art-library/ab123456-2")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        for directory in [art, cache] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let original = Data("original art".utf8)
        let image = Data("MDPro3 image fixture".utf8)
        let patched = Data("UnityFS\0cached art".utf8)
        try image.write(to: art.appendingPathComponent("2.jpg"))
        try patched.write(to: cache.appendingPathComponent("2.bundle"))
        let manifest = """
        [{"name":"Test","path":"ab/ab123456","originalSHA256":"\(artworkDigest(original))",
          "sourceArtwork":{"format":1,"cid":11,"sha256":"\(artworkDigest(image))"},
          "variants":[{"id":2,"sha256":"\(artworkDigest(patched))"}]}]
        """
        try Data(manifest.utf8).write(to: cache.appendingPathComponent("manifest.json"))
        let variant = SearchCard.Variant(id: 2, file: "2.jpg")
        let card = SearchCard(id: "11", cid: 11, masterName: "Test", proName: nil, codes: [], masterIDs: [],
                              variants: [variant], path: "ab/ab123456", series: nil)
        let engine = CardSearchEngine(storage: folder, proDirectory: folder)
        let reused = try engine.makePack(card: card, variant: variant, original: original)
        try expect(reused.directory.path == cache.path)
        print("PASS reusing verified generated artwork without running the patch helper")
    }

    private static func resourceReuse() throws {
        let game = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let root = game.appendingPathComponent("LocalData")
        let source = root.appendingPathComponent("aaaa1111/0000/ab")
        let target = root.appendingPathComponent("bbbb2222/0000/ab")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: game) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let reuse = ResourceReuse(root: root)
        let before = try reuse.accountDirectories()
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let discovered = try reuse.newDirectory(since: before)
        try expect(discovered == "bbbb2222")

        let original = Data("new account file".utf8)
        let sourceData = Data("source asset".utf8)
        let sourceAsset = source.appendingPathComponent("ab123456")
        let targetAsset = target.appendingPathComponent("ab123456")
        try sourceData.write(to: sourceAsset)
        try original.write(to: targetAsset)
        let missing = source.appendingPathComponent("ab999999")
        try Data().write(to: missing)
        let sparse = try FileHandle(forWritingTo: missing)
        try sparse.truncate(atOffset: 1_073_741_824)
        try sparse.close()
        try Data([1]).write(to: source.appendingPathComponent("other"))
        let sourceIndex = source.deletingLastPathComponent().appendingPathComponent("86/868ffd0e")
        let targetIndex = target.deletingLastPathComponent().appendingPathComponent("86/868ffd0e")
        for file in [sourceIndex, targetIndex] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let empty = Data(#"{"informations":[]}"#.utf8)
        let complete = Data("""
            {"informations":[{"assetName":"ab/ab999999","version":"1","bytes":1073741824,
            "crc":"\(String(repeating: "a", count: 64))"}]}
            """.utf8)
        try complete.write(to: sourceIndex)
        try empty.write(to: targetIndex)

        var checks = 0
        try expectError("game still open") {
            _ = try reuse.prepare(target: "bbbb2222", source: "aaaa1111") {
                checks += 1
                if checks == 2 { throw SwitchError("game still open") }
            }
        }
        try expect(!reuse.hasBackup(for: "bbbb2222"))
        try expect(!fm.fileExists(atPath: target.appendingPathComponent("ab999999").path))
        let result = try reuse.prepare(target: "bbbb2222", source: "aaaa1111") {}
        try expect(result.clonedFiles == 1 && reuse.hasBackup(for: "bbbb2222"))
        let installedIndex = try Data(contentsOf: targetIndex)
        try expect(installedIndex == complete)
        // Simulate the previous app version retaining the empty game index.
        try empty.write(to: targetIndex, options: .atomic)
        let repaired = try reuse.prepare(target: "bbbb2222", source: "aaaa1111") {}
        let repairedIndex = try Data(contentsOf: targetIndex)
        try expect(repaired.clonedFiles == 0 && repairedIndex == complete)
        let retained = try Data(contentsOf: targetAsset)
        try expect(retained == original)
        try expect(!fm.fileExists(atPath: target.appendingPathComponent("other").path))
        let cloned = target.appendingPathComponent("ab999999")
        let file = try FileHandle(forWritingTo: cloned)
        try file.truncate(atOffset: 1)
        try file.close()
        let sourceSize = try missing.resourceValues(forKeys: [.fileSizeKey]).fileSize
        try expect(sourceSize == 1_073_741_824)

        try reuse.restore(target: "bbbb2222") {}
        try expect(!reuse.hasBackup(for: "bbbb2222") && !fm.fileExists(atPath: cloned.path))
        let restored = try Data(contentsOf: targetAsset)
        try expect(restored == original)
        let restoredIndex = try Data(contentsOf: targetIndex)
        try expect(restoredIndex == empty)
        print("PASS resource discovery, APFS clone, index repair, and atomic restoration")

        let installation = SteamInstallation(wine: game, bottle: game, steam: game, game: game)
        for folder in ["config", "logs"] {
            try fm.createDirectory(at: game.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(fixture.utf8).write(to: installation.loginFile)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let birth = try target.deletingLastPathComponent().deletingLastPathComponent()
            .resourceValues(forKeys: [.creationDateKey]).creationDate!
        let loggedIn = formatter.string(from: birth.addingTimeInterval(-5))
        let launched = formatter.string(from: birth.addingTimeInterval(-3))
        try log(secondID).replacingOccurrences(of: "2000-01-01 00:00:00", with: loggedIn)
            .write(to: installation.logFile, atomically: true, encoding: .utf8)
        try "[\(launched)] AppID 1449850 adding PID 123 as a tracked process masterduel.exe"
            .write(to: installation.gameLog, atomically: true, encoding: .utf8)
        let existing = try reuse.existingDirectory(for: secondID, excluding: ["aaaa1111"],
                                                   connectionLog: installation.logFile, gameLog: installation.gameLog)
        let wrong = try reuse.existingDirectory(for: firstID, excluding: ["aaaa1111"],
                                                connectionLog: installation.logFile, gameLog: installation.gameLog)
        try expect(existing == "bbbb2222" && wrong == nil)
        print("PASS safe association of a previously launched account")

        let client = FakeClient(logFile: installation.logFile)
        let fresh = root.appendingPathComponent("cccc3333/0000")
        client.onGameLaunch = {
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        }
        let switcher = Switcher(installation: installation, client: client,
                                storage: game.appendingPathComponent("support"))
        var recorded: String?
        try switcher.changeAccount(to: secondID, launchGame: true,
            resourceLaunch: .init(source: "aaaa1111", target: nil, otherAccounts: ["bbbb2222"]),
            recordResourceDirectory: { recorded = $0 })
        try expect(recorded == "cccc3333")
        try expect(client.events == ["registry:second", "start", "game", "closeGame", "game"])
        let freshIndex = try Data(contentsOf: fresh.appendingPathComponent("86/868ffd0e"))
        try expect(freshIndex == complete)

        client.active.remove("masterduel.exe")
        client.events = []
        try switcher.changeAccount(to: secondID, launchGame: true,
            resourceLaunch: .init(source: "aaaa1111", target: "cccc3333", otherAccounts: ["bbbb2222"]))
        try expect(client.events == ["stop", "start", "game"])
        print("PASS automatic first launch and direct repeat launch")
    }

    private static func installationPaths() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let apps = home.appendingPathComponent("Applications")
        let wine = apps.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        let bottles = home.appendingPathComponent("Custom Bottles")
        let bottle = bottles.appendingPathComponent("Renamed")
        let steam = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let library = home.appendingPathComponent("External Disk/SteamLibrary")
        let game = library.appendingPathComponent("steamapps/common/Master Duel")
        let pro = bottle.appendingPathComponent("drive_c/Program Files/Renamed Art Folder")
        func write(_ text: String, to path: URL) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }
        try write("", to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try write("", to: steam.appendingPathComponent("Steam.exe"))
        try fm.createDirectory(at: bottle.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bottle.appendingPathComponent("dosdevices/e:"), withDestinationURL: library.deletingLastPathComponent())
        try write(#""libraryfolders" { "1" { "path" "E:\\SteamLibrary" } }"#, to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        try write(#""AppState" { "appid" "1449850" "installdir" "Master Duel" }"#,
                  to: library.appendingPathComponent("steamapps/appmanifest_1449850.acf"))
        try write("", to: game.appendingPathComponent("masterduel.exe"))
        try write("", to: pro.appendingPathComponent("Data/locales/zh-CN/cards.cdb"))
        try write("", to: pro.appendingPathComponent("Data/cards_Lite.json"))
        try fm.createDirectory(at: pro.appendingPathComponent("Picture/Art"), withIntermediateDirectories: true)
        let moved = home.appendingPathComponent("Missing")
        let install = try SteamInstallation.discover(home: home, applications: [apps], bottleRoots: [bottles],
                                                     preferredGame: moved)
        try expect(install.game == InstallationPaths.canonical(game))
        try expectError("Steam 已登记") {
            _ = try SteamInstallation.discover(home: home, applications: [apps], bottleRoots: [bottles],
                                               preferredGame: moved, requirePreferred: true)
        }
        try expect(InstallationPaths.discoverMDPro3(preferred: moved, home: home, bottleRoots: [bottles])
                   == InstallationPaths.canonical(pro))
        print("PASS discovering renamed CrossOver installs and external Steam libraries")
    }

    private static func preferences() throws {
        let data = Data(fixture.utf8)
        let users = try LoginUsers(data)
        let updated = try users.selecting(secondID)
        let text = String(decoding: updated, as: UTF8.self)
        try expect(text.contains("\"Custom\" { \"Leave\" \"untouched\" }"))
        try expect(text.contains("大号 🐉"))
        try expect(text.replacingOccurrences(of: #""AutoLogin" "[01]""#, with: "", options: .regularExpression)
                   == fixture.replacingOccurrences(of: #""AutoLogin" "[01]""#, with: "", options: .regularExpression))
        let accounts = try LoginUsers(updated).accounts
        try expect(accounts.filter(\.preferred).map(\.id) == [secondID])

        let legacy = fixture.replacingOccurrences(of: "AutoLogin", with: "MostRecent")
            .replacingOccurrences(of: "\"MostRecent\" \"0\"", with: "")
        let legacyChanged = try LoginUsers(Data(legacy.utf8)).selecting(secondID)
        let legacyAccounts = try LoginUsers(legacyChanged).accounts
        try expect(legacyAccounts.filter(\.preferred).map(\.id) == [secondID])
        try expectError("格式") { _ = try LoginUsers(Data(fixture.dropLast().utf8)) }
        print("PASS account parsing and minimal edits")
    }

    private static func authentication() throws {
        try expect(ConnectionLog.activeAccount(in: log(secondID)) == secondID)
        try expect(ConnectionLog.activeAccount(in: log(secondID) + " LogOff()\r\n") == nil)
        try expect(ConnectionLog.activeAccount(in: log(firstID) + log(secondID)) == secondID)
        let incomplete = log(secondID).components(separatedBy: .newlines).first ?? ""
        try expect(ConnectionLog.activeAccount(in: incomplete) == nil)
        print("PASS fresh login, CRLF, and logoff")
    }

    private static func run(_ title: String, _ body: (Switcher, FakeClient) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = root.appendingPathComponent("config")
        let logs = root.appendingPathComponent("logs")
        for path in [config, logs] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let installation = SteamInstallation(wine: root, bottle: root, steam: root)
        try Data(fixture.utf8).write(to: installation.loginFile)
        let resource = root.appendingPathComponent("LocalData")
        let savedata = root.appendingPathComponent("LocalSave")
        let sentinel = Data([1, 2, 3])
        for path in [resource, savedata] { try sentinel.write(to: path) }
        let client = FakeClient(logFile: installation.logFile)
        let switcher = Switcher(installation: installation, client: client,
                                storage: root.appendingPathComponent("support"))
        try body(switcher, client)
        for path in [resource, savedata] {
            let result = try Data(contentsOf: path)
            try expect(result == sentinel)
        }
        print("PASS \(title)")
    }

    private static func expect(_ condition: Bool, line: Int = #line) throws {
        guard condition else { throw SwitchError("Check failed at line \(line).") }
    }

    private static func expectError(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            guard error.localizedDescription.contains(message) else { throw error }
            return
        }
        throw SwitchError("Expected failure: \(message)")
    }

    private static func log(_ id: UInt64) -> String {
        let user = "[U:1:\(id - SteamAccount.individualBase)]"
        return """
        [2000-01-01 00:00:00] [Logging On, 4, 7] \(user) RecvMsgClientLogOnResponse() : \(user) 'OK'\r
        [2000-01-01 00:00:00] [Logged On, 4, 7] \(user) RecvMsgClientLogOnResponse() : processing complete\r

        """
    }

    private final class FakeClient: SteamClient, @unchecked Sendable {
        let logFile: URL
        var active: Set<String> = []
        var events: [String] = []
        var username: String? = "first"
        var loginID: UInt64? = secondID
        var failStart = false
        var refuseRestore = false
        var onGameLaunch: (() throws -> Void)?
        var onActiveAccount: () -> UInt64? = { nil }
        var royalPIDs: [UInt32] = []

        init(logFile: URL) { self.logFile = logFile }

        func processes() throws -> Set<String> { active }
        func activeAccount() throws -> UInt64? { onActiveAccount() }

        func stop() throws {
            events.append("stop")
            active.remove("steam.exe")
        }

        func start(username: String) throws {
            events.append("start")
            if failStart { throw SwitchError("Steam 启动失败。") }
            active.insert("steam.exe")
            guard let loginID else { return }
            let data = Data(log(loginID).utf8)
            if FileManager.default.fileExists(atPath: logFile.path) {
                let handle = try FileHandle(forWritingTo: logFile)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let nextSecond = formatter.string(from: Date().addingTimeInterval(1))
                let fresh = log(loginID).replacingOccurrences(of: "2000-01-01 00:00:00", with: nextSecond)
                try Data(fresh.utf8).write(to: logFile)
            }
        }

        var staleDisplay = false
    func displayNeedsRefresh() throws -> Bool { staleDisplay }
    func resetDisplaySession() throws {
        staleDisplay = false
        events.append("display-refresh")
    }

    func activateRoyalFinish(_ cardIDs: Set<Int>, storage: URL, expectedPID: UInt32?) throws {
        events.append("royal:\(cardIDs.sorted())")
        if let expectedPID { royalPIDs.append(expectedPID) }
    }

    func launchGame() throws {
            events.append("game")
            active.insert("masterduel.exe")
            try onGameLaunch?()
        }

        func closeGame() throws {
            events.append("closeGame")
            active.remove("masterduel.exe")
        }

        func autoLoginUser() throws -> String? { username }

        func setAutoLoginUser(_ username: String?) throws {
            if refuseRestore && username == "first" { throw SwitchError("模拟恢复失败。") }
            events.append("registry:\(username ?? "(empty)")")
            self.username = username
        }
    }
}

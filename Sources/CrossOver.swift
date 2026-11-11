import CoreGraphics
import Foundation

struct SteamInstallation: Sendable {
    static let appID = "1449850"
    let wine: URL
    let bottle: URL
    let steam: URL
    var game: URL? = nil

    var loginFile: URL { steam.appendingPathComponent("config/loginusers.vdf") }
    var logFile: URL { steam.appendingPathComponent("logs/connection_log.txt") }
    var gameLog: URL { steam.appendingPathComponent("logs/gameprocess_log.txt") }
    var bottleName: String { bottle.lastPathComponent }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         applications: [URL]? = nil,
                         bottleRoots: [URL]? = nil, preferredGame: URL? = nil,
                         requirePreferred: Bool = false) throws -> SteamInstallation {
        let manager = FileManager.default
        let apps = applications ?? [URL(fileURLWithPath: "/Applications"),
                                    home.appendingPathComponent("Applications")]
        let launchers = apps.map {
            $0.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        }
        guard let wine = launchers.first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
            throw SwitchError("找不到 CrossOver.app。请将 CrossOver 放在「应用程序」中。")
        }
        let bottles = InstallationPaths.bottles(in: bottleRoots ?? InstallationPaths.bottleRoots(home: home))
        var found: [SteamInstallation] = []
        for bottle in bottles {
            let drive = bottle.appendingPathComponent("drive_c")
            for root in ["Program Files (x86)/Steam", "Program Files/Steam", "Steam"] {
                let steam = drive.appendingPathComponent(root)
                guard manager.fileExists(atPath: steam.appendingPathComponent("Steam.exe").path) else { continue }
                for library in steamLibraries(steam: steam, bottle: bottle) {
                    guard let game = masterDuel(in: library) else { continue }
                    found.append(SteamInstallation(wine: wine, bottle: bottle, steam: steam, game: game))
                }
            }
        }
        if let preferredGame {
            let matches = found.filter { $0.game.map(InstallationPaths.canonical) == InstallationPaths.canonical(preferredGame) }
            if matches.count == 1, let installation = matches.first { return installation }
            if requirePreferred {
                throw SwitchError(matches.isEmpty
                    ? "这个目录不是 CrossOver 中 Steam 已登记的 Master Duel 安装。请选择包含 masterduel.exe 的游戏文件夹。"
                    : "这份 Master Duel 同时关联到多个 Steam 安装，请在 Steam 中检查游戏库。")
            }
        }
        guard found.count == 1, let installation = found.first else {
            throw SwitchError(found.isEmpty
                ? "找不到 CrossOver 中已安装的 Master Duel。请在「设置 → 安装目录」检查游戏位置。"
                : "找到了多个 Master Duel 安装。请在「设置 → 安装目录」选择游戏位置。")
        }
        return installation
    }

    private static func steamLibraries(steam: URL, bottle: URL) -> [URL] {
        let config = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        let libraries = (try? KeyValues(data: Data(contentsOf: config)))?.entries.entry("libraryfolders")?.children
        let listed = libraries?.compactMap { entry -> URL? in
            guard Int(entry.key) != nil,
                  let path = entry.children?.entry("path")?.text ?? entry.text else { return nil }
            let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
            guard let drive = parts.first?.lowercased(), drive.count == 2, drive.last == ":",
                  !parts.dropFirst().contains("..") else { return nil }
            let root = drive == "c:" ? bottle.appendingPathComponent("drive_c")
                : bottle.appendingPathComponent("dosdevices").appendingPathComponent(drive)
            return parts.dropFirst().reduce(root) { $0.appendingPathComponent(String($1)) }
        } ?? []
        var seen = Set<URL>()
        return ([steam] + listed).filter { seen.insert(InstallationPaths.canonical($0)).inserted }
    }

    private static func masterDuel(in library: URL) -> URL? {
        let apps = library.appendingPathComponent("steamapps")
        let manifest = apps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let info = try? KeyValues(data: Data(contentsOf: manifest)),
              let fields = info.entries.entry("AppState")?.children,
              fields.entry("appid")?.text == appID,
              let directory = fields.entry("installdir")?.text, !directory.isEmpty,
              directory != ".", directory != "..", !directory.contains("/"), !directory.contains("\\")
        else { return nil }
        let game = apps.appendingPathComponent("common").appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: game.appendingPathComponent("masterduel.exe").path)
        else { return nil }
        return InstallationPaths.canonical(game)
    }

    func readLoginFile() throws -> Data {
        let type = try loginFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard type.isRegularFile == true, type.isSymbolicLink != true else {
            throw SwitchError("Steam 登录配置不是普通文件，操作已停止。")
        }
        return try Data(contentsOf: loginFile)
    }
}

protocol SteamClient: Sendable {
    func processes() throws -> Set<String>
    func activeAccount() throws -> UInt64?
    func stop() throws
    func start(username: String) throws
    func launchGame() throws
    func activateRoyalFinish(_ cardIDs: Set<Int>, storage: URL, expectedPID: UInt32?) throws
    func displayNeedsRefresh() throws -> Bool
    func resetDisplaySession() throws
    func closeGame() throws
    func autoLoginUser() throws -> String?
    func setAutoLoginUser(_ username: String?) throws
}

struct CrossOverClient: SteamClient {
    private static let steamKey = #"HKCU\Software\Valve\Steam"#
    private static let valueName = "AutoLoginUser"
    let install: SteamInstallation
    var components = Bundle.main.resourceURL?.appendingPathComponent("RoyalFinish")

    private var displayLoader: URL? {
        guard let loader = components?.appendingPathComponent("MDRoyalLoader.exe"),
              FileManager.default.fileExists(atPath: loader.path) else { return nil }
        return loader
    }

    func processes() throws -> Set<String> {
        let output = try run("tasklist.exe", ["/FO", "CSV", "/NH"], name: "检查 Bottle 进程")
        let names = Set(output.components(separatedBy: .newlines).compactMap { row -> String? in
            guard row.hasPrefix("\""), let end = row.dropFirst().firstIndex(of: "\"") else { return nil }
            return row[row.index(after: row.startIndex)..<end].lowercased()
        })
        guard names.contains("tasklist.exe") else {
            throw SwitchError("无法确认 Bottle 里的进程状态，操作已停止。")
        }
        return names
    }

    func activeAccount() throws -> UInt64? {
        let key = Self.steamKey + #"\ActiveProcess"#
        let output = try run("reg.exe", ["query", key], name: "读取 Steam 当前账号")
        var values: [String: UInt32] = [:]
        for row in output.components(separatedBy: .newlines) {
            let columns = row.split(whereSeparator: \.isWhitespace)
            guard columns.count == 3, columns[1] == "REG_DWORD",
                  columns[2].hasPrefix("0x"), let value = UInt32(columns[2].dropFirst(2), radix: 16)
            else { continue }
            values[columns[0].lowercased()] = value
        }
        guard let user = values["activeuser"], user != 0, let pid = values["pid"], pid != 0 else { return nil }
        let running = try run("tasklist.exe", ["/FI", "PID eq \(pid)", "/FO", "CSV", "/NH"],
                              name: "核对 Steam 当前进程")
        let match = "\"steam.exe\",\"\(pid)\","
        guard running.components(separatedBy: .newlines).contains(where: {
            $0.lowercased().hasPrefix(match)
        }) else { return nil }
        return SteamAccount.individualBase + UInt64(user)
    }

    func stop() throws {
        try steam(["-shutdown"], name: "正常退出 Steam")
    }

    func start(username: String) throws {
        try steam(["-login", username], name: "启动 Steam")
    }

    private struct DisplaySize: Equatable {
        let width: Int
        let height: Int
    }

    func displayNeedsRefresh() throws -> Bool {
        let display = CGMainDisplayID()
        guard let loader = displayLoader, let mode = CGDisplayCopyDisplayMode(display) else { return false }
        let current = try displaySize(using: loader)
        let expected = [DisplaySize(width: mode.width, height: mode.height),
                        DisplaySize(width: mode.pixelWidth, height: mode.pixelHeight)]
        return !expected.contains(current)
    }

    func resetDisplaySession() throws {
        let server = install.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            throw SwitchError("找不到 CrossOver 的会话管理程序。")
        }
        for command in ["-k", "-w"] {
            let process = Process()
            process.executableURL = server
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = install.bottle.path
            process.environment = environment
            process.arguments = [command]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 10) == .success, process.terminationStatus == 0 else {
                if process.isRunning { process.terminate() }
                throw SwitchError("无法刷新 CrossOver 会话里的屏幕模式。")
            }
        }
        guard try !displayNeedsRefresh() else {
            throw SwitchError("CrossOver 仍未识别到当前屏幕，请检查容器的显示设置。")
        }
    }

    func launchGame() throws {
        var arguments = ["-applaunch", SteamInstallation.appID, "-screen-fullscreen", "1", "-window-mode", "borderless"]
        if let loader = displayLoader {
            let size = try displaySize(using: loader)
            arguments += ["-screen-width", String(size.width), "-screen-height", String(size.height)]
        }
        try steam(arguments, name: "启动 Master Duel")
    }

    private func displaySize(using loader: URL) throws -> DisplaySize {
        let output = try run(windowsPath(loader), ["probe-display"], name: "检测 CrossOver 当前屏幕")
        guard let row = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("MD_DISPLAY=") }) else {
            throw SwitchError("CrossOver 未报告当前屏幕分辨率。")
        }
        let values = row.dropFirst("MD_DISPLAY=".count).split(separator: ",").compactMap { Int($0) }
        guard values.count == 2, values.allSatisfy({ (320...16_384).contains($0) }) else {
            throw SwitchError("CrossOver 报告的屏幕分辨率无效。")
        }
        return DisplaySize(width: values[0], height: values[1])
    }

    func activateRoyalFinish(_ cardIDs: Set<Int>, storage: URL, expectedPID: UInt32?) throws {
        guard let game = install.game, let components else {
            throw SwitchError("找不到动态镜碎组件。")
        }
        let manager = FileManager.default
        let loader = components.appendingPathComponent("MDRoyalLoader.exe")
        let renderer = components.appendingPathComponent("MDRoyalFinish.dll")
        guard manager.fileExists(atPath: loader.path), manager.fileExists(atPath: renderer.path)
        else { throw SwitchError("这个构建缺少动态镜碎组件。") }
        let selection = storage.appendingPathComponent("royal-finish-\(UUID().uuidString).bin")
        let log = storage.appendingPathComponent("royal-finish.log")
        try manager.createDirectory(at: storage, withIntermediateDirectories: true)
        try RoyalFinish.selectionFile(cardIDs).write(to: selection, options: .atomic)
        defer { try? manager.removeItem(at: selection) }
        var arguments = try [
            windowsPath(game.appendingPathComponent("masterduel.exe")), windowsPath(renderer),
            windowsPath(selection), windowsPath(log)
        ]
        if let expectedPID { arguments.append(String(expectedPID)) }
        let result = try run(windowsPath(loader), arguments, name: "加载动态镜碎", timeout: 45)
        let status = result.split(whereSeparator: \.isNewline).last(where: {
            $0.hasPrefix("MD_ROYAL_RESULT=")
        }).flatMap { Int($0.dropFirst("MD_ROYAL_RESULT=".count)) }
        guard status == 0 else {
            let detail = switch status {
            case 11: "找不到本次启动的游戏进程。"
            case 102, 104, 105: "当前游戏版本的卡面渲染接口不匹配。"
            case 103, 14: "等待游戏渲染组件超时。"
            default: "CrossOver 未能启用渲染组件。"
            }
            throw SwitchError(detail + "（\(status.map(String.init) ?? "未知状态")）")
        }
    }

    private func windowsPath(_ url: URL) throws -> String {
        let path = InstallationPaths.canonical(url).path
        let devices = install.bottle.appendingPathComponent("dosdevices")
        let mapped = (try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? []
        let drives = mapped.compactMap { mapping -> (String, String)? in
            let name = mapping.lastPathComponent
            guard name.utf8.count == 2, name.hasSuffix(":"), name.first?.isASCII == true,
                  name.first?.isLetter == true else { return nil }
            let root = InstallationPaths.canonical(mapping).path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path.hasPrefix(prefix) ? (name.uppercased(), prefix) : nil
        }
        guard let (drive, prefix) = drives.max(by: { $0.1.count < $1.1.count }) else {
            throw SwitchError("CrossOver 无法访问动态镜碎组件或游戏所在的目录。")
        }
        return drive + "\\" + path.dropFirst(prefix.count).replacingOccurrences(of: "/", with: "\\")
    }

    func closeGame() throws {
        _ = try run("taskkill.exe", ["/IM", "masterduel.exe"], name: "正常关闭初始化的 Master Duel")
    }

    func autoLoginUser() throws -> String? {
        let output = try run("reg.exe", ["query", Self.steamKey], name: "读取 Steam 自动登录设置")
        guard let row = output.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
                .first?.lowercased() == Self.valueName.lowercased()
        }) else { return nil }
        let columns = row.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard columns.count >= 2, columns[1] == "REG_SZ" else {
            throw SwitchError("Steam 自动登录设置类型异常。")
        }
        let username = columns.count == 3 ? String(columns[2]).trimmingCharacters(in: .whitespaces) : ""
        guard username.isEmpty || username.range(of: #"^[A-Za-z0-9_]{1,64}$"#,
                                                  options: .regularExpression) != nil else {
            throw SwitchError("Steam 自动登录账号格式异常。")
        }
        return username
    }

    func setAutoLoginUser(_ username: String?) throws {
        let arguments = if let username {
            ["add", Self.steamKey, "/v", Self.valueName, "/t", "REG_SZ", "/d", username, "/f"]
        } else {
            ["delete", Self.steamKey, "/v", Self.valueName, "/f"]
        }
        _ = try run("reg.exe", arguments, name: "写入 Steam 自动登录设置")
    }

    private func steam(_ arguments: [String], name: String) throws {
        let drivePrefix = install.bottle.appendingPathComponent("drive_c").path + "/"
        guard install.steam.path.hasPrefix(drivePrefix) else {
            throw SwitchError("Steam 不在目标 Bottle 的 C 盘。")
        }
        let relative = String(install.steam.path.dropFirst(drivePrefix.count))
        let windowsDirectory = "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
        try run(windowsDirectory + "\\Steam.exe", arguments, name: name,
                options: ["--no-wait", "--workdir", windowsDirectory])
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], name: String,
                     options: [String] = [], timeout: TimeInterval = 15) throws -> String {
        let process = Process()
        process.executableURL = install.wine
        var environment = ProcessInfo.processInfo.environment
        environment["CX_BOTTLE_PATH"] = install.bottle.deletingLastPathComponent().path
        process.environment = environment
        process.arguments = ["--bottle", install.bottleName, "--no-update", "--no-gui"]
            + options + ["--cx-app", executable] + arguments

        // Read stdout concurrently. Detached Wine children may inherit stdout,
        // so launch requests send both streams directly to /dev/null.
        let output = Pipe()
        let capturesOutput = !options.contains("--no-wait")
        process.standardOutput = capturesOutput ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let read = CapturedOutput()
        if capturesOutput {
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                read.append(data)
            }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() }
        catch { throw SwitchError("无法\(name)。请检查 CrossOver 是否可以打开该 Bottle。") }
        if capturesOutput { try? output.fileHandleForWriting.close() }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            throw SwitchError("\(name)超时。")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SwitchError("\(name)失败。")
        }
        if capturesOutput, read.finished.wait(timeout: .now() + 2) != .success {
            throw SwitchError("无法取得\(name)的结果。")
        }
        return String(decoding: read.bytes, as: UTF8.self)
    }
}

private final class CapturedOutput: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    var bytes: Data { lock.withLock { data } }

    func append(_ bytes: Data) {
        if bytes.isEmpty { finished.signal() }
        else { lock.withLock { data.append(bytes) } }
    }
}

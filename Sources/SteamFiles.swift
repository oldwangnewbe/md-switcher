import Foundation

struct SwitchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SteamAccount: Identifiable, Equatable {
    static let individualBase: UInt64 = 76561197960265728
    let id: UInt64
    let username: String
    let persona: String
    let remembered: Bool
    let preferred: Bool
    var displayName: String { persona.isEmpty ? username : persona }
}

struct KeyValues {
    struct Token {
        let raw: String
        let range: NSRange

        var value: String {
            guard raw.hasPrefix("\"") else { return raw }
            let content = raw.dropFirst().dropLast()
            var decoded = ""
            var index = content.startIndex
            while index != content.endIndex {
                let character = content[index]
                content.formIndex(after: &index)
                if character == "\\", index != content.endIndex,
                   content[index] == "\\" || content[index] == "\"" {
                    decoded.append(content[index])
                    content.formIndex(after: &index)
                } else {
                    decoded.append(character)
                }
            }
            return decoded
        }
    }

    indirect enum Value {
        case text(Token)
        case block([Entry], closing: NSRange)
    }

    struct Entry {
        let key: String
        let value: Value

        var text: String? {
            if case .text(let token) = value { return token.value }
            return nil
        }

        var children: [Entry]? {
            if case .block(let entries, _) = value { return entries }
            return nil
        }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"\s+|//[^\r\n]*|[{}]|"(?:\\[^\r\n]|[^"\\\r\n])*"|[^\s{}"]+"#
    )

    let source: String
    let entries: [Entry]

    init(data: Data) throws {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw SwitchError("Steam 配置不是有效的 UTF-8。")
        }
        source = decoded
        let string = decoded as NSString
        let hasBOM = decoded.hasPrefix("\u{feff}")
        var offset = hasBOM ? 1 : 0
        var tokens: [Token] = []
        let range = NSRange(location: offset, length: string.length - offset)
        for match in Self.pattern.matches(in: decoded, range: range) {
            guard match.range.location == offset else { throw Self.invalid }
            offset = NSMaxRange(match.range)
            let raw = string.substring(with: match.range)
            if !raw.hasPrefix("//"), raw.first?.isWhitespace == false {
                tokens.append(Token(raw: raw, range: match.range))
            }
        }
        guard offset == string.length else { throw Self.invalid }
        var index = 0
        entries = try Self.parse(tokens, index: &index, depth: 0).0
    }

    private static var invalid: SwitchError { SwitchError("Steam 配置格式异常，操作已停止。") }

    private static func parse(_ tokens: [Token], index: inout Int, depth: Int) throws
        -> ([Entry], NSRange?) {
        guard depth < 32 else { throw invalid }
        var entries: [Entry] = []
        while index < tokens.count {
            let key = tokens[index]
            index += 1
            if key.raw == "}", depth > 0 { return (entries, key.range) }
            guard key.raw != "}", key.raw != "{", index < tokens.count else { throw invalid }
            let token = tokens[index]
            index += 1
            if token.raw == "{" {
                let (children, closing) = try parse(tokens, index: &index, depth: depth + 1)
                guard let closing else { throw invalid }
                entries.append(Entry(key: key.value, value: .block(children, closing: closing)))
            } else {
                guard token.raw != "}" else { throw invalid }
                entries.append(Entry(key: key.value, value: .text(token)))
            }
        }
        guard depth == 0 else { throw invalid }
        return (entries, nil)
    }
}

extension Array where Element == KeyValues.Entry {
    func entry(_ key: String) -> KeyValues.Entry? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}

struct LoginUsers {
    private struct Record {
        let id: UInt64
        let fields: [KeyValues.Entry]
        let closing: NSRange
    }

    private static let supportedFlags = ["autologin", "mostrecent"]
    private let file: KeyValues
    private let records: [Record]
    let accounts: [SteamAccount]

    init(_ data: Data) throws {
        let file = try KeyValues(data: data)
        guard file.entries.count == 1, let users = file.entries.entry("users")?.children else {
            throw SwitchError("找不到 Steam 账号列表。")
        }
        var ids = Set<UInt64>()
        var usernames = Set<String>()
        var records: [Record] = []
        var accounts: [SteamAccount] = []
        for user in users {
            guard let id = UInt64(user.key), id > SteamAccount.individualBase,
                  id - SteamAccount.individualBase <= UInt64(UInt32.max),
                  ids.insert(id).inserted,
                  case .block(let fields, let closing) = user.value,
                  let username = fields.entry("AccountName")?.text,
                  username.range(of: #"^[A-Za-z0-9_]{1,64}$"#, options: .regularExpression) != nil,
                  usernames.insert(username.lowercased()).inserted else {
                throw SwitchError("Steam 账号列表中存在无法识别或重复的账号。")
            }
            for key in ["accountname", "rememberpassword"] + Self.supportedFlags {
                let matches = fields.filter { $0.key.lowercased() == key }
                guard matches.count <= 1, matches.allSatisfy({ $0.text != nil }) else {
                    throw SwitchError("Steam 登录设置中存在无法识别的字段。")
                }
            }
            records.append(Record(id: id, fields: fields, closing: closing))
            accounts.append(SteamAccount(
                id: id, username: username, persona: fields.entry("PersonaName")?.text ?? "",
                remembered: fields.entry("RememberPassword")?.text == "1",
                preferred: (fields.entry("AutoLogin") ?? fields.entry("MostRecent"))?.text == "1"
            ))
        }
        self.file = file
        self.records = records
        self.accounts = accounts
    }

    func selecting(_ id: UInt64) throws -> Data {
        guard accounts.contains(where: { $0.id == id && $0.remembered }) else {
            throw SwitchError("请先在 Steam 中登录此账号，并勾选记住登录。")
        }
        let flags = Self.supportedFlags.compactMap { flag in
            records.lazy.compactMap { $0.fields.entry(flag)?.key }.first
        }
        guard !flags.isEmpty else {
            throw SwitchError("此 Steam 版本的自动登录设置无法识别。")
        }
        var edits: [(NSRange, String)] = []
        for record in records {
            let desired = record.id == id ? "1" : "0"
            var additions = ""
            for flag in flags {
                if let field = record.fields.entry(flag), case .text(let token) = field.value {
                    guard ["0", "1"].contains(token.value) else {
                        throw SwitchError("Steam 自动登录字段格式异常。")
                    }
                    if token.value != desired { edits.append((token.range, "\"\(desired)\"")) }
                } else {
                    additions += "\t\"\(flag)\"\t\t\"\(desired)\"\n\t"
                }
            }
            if !additions.isEmpty {
                edits.append((NSRange(location: record.closing.location, length: 0), additions))
            }
        }
        let updated = NSMutableString(string: file.source)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            updated.replaceCharacters(in: range, with: replacement)
        }
        return Data((updated as String).utf8)
    }
}

struct ConnectionLog {
    private static let success = try! NSRegularExpression(
        pattern: #"\[Logging On,\s*\d+,\s*\d+\] \[U:1:(\d+)\] RecvMsgClientLogOnResponse\(\) : \[U:1:(\d+)\] 'OK'\s*$"#
    )
    private static let complete = try! NSRegularExpression(
        pattern: #"\[Logged On,\s*\d+,\s*\d+\] \[U:1:(\d+)\] RecvMsgClientLogOnResponse\(\) : processing complete\s*$"#
    )

    static func activeAccount(in log: String) -> UInt64? {
        var pending: UInt64?
        var active: UInt64?
        for line in log.components(separatedBy: .newlines) {
            let text = line as NSString
            let range = NSRange(location: 0, length: text.length)
            if let match = success.firstMatch(in: String(line), range: range),
               let account = UInt32(text.substring(with: match.range(at: 1))), account != 0,
               text.substring(with: match.range(at: 1)) == text.substring(with: match.range(at: 2)) {
                pending = SteamAccount.individualBase + UInt64(account)
                active = nil
            } else if let match = complete.firstMatch(in: String(line), range: range),
                      let account = UInt32(text.substring(with: match.range(at: 1))),
                      pending == SteamAccount.individualBase + UInt64(account) {
                active = pending
                pending = nil
            } else if line.contains(" LogOff()") || line.contains(" ConnectionDisconnected(")
                        || line.contains("CCMInterface::SetSteamID(")
                        || line.contains("RecvMsgClientLogOnResponse() :") {
                pending = nil
                active = nil
            }
        }
        return active
    }
}

struct GameLaunchHistory {
    struct Start {
        let stamp: String
        let time: Date
    }

    let starts: [Start]
    private let steamLines: [String]

    init?(connectionLog: URL, gameLog: URL) {
        guard let launches = try? Data(contentsOf: gameLog),
              let connections = try? Data(contentsOf: connectionLog) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        starts = String(decoding: launches, as: UTF8.self).components(separatedBy: .newlines).filter {
            $0.contains("AppID 1449850 adding PID ") && $0.lowercased().contains("masterduel.exe")
        }.compactMap { line in
            let stamp = String(line.prefix(21))
            return formatter.date(from: String(stamp.dropFirst().dropLast())).map { Start(stamp: stamp, time: $0) }
        }.sorted { $0.time < $1.time }
        steamLines = String(decoding: connections, as: UTF8.self).components(separatedBy: .newlines)
    }

    func account(at start: Start) -> UInt64? {
        let preceding = steamLines.filter { $0.hasPrefix("[") && $0.prefix(21) <= start.stamp[...] }
        return ConnectionLog.activeAccount(in: preceding.joined(separator: "\n"))
    }
}

struct LogCheckpoint {
    private let url: URL
    private let fileID: String?
    private let offset: UInt64
    private let anchor: Data
    private let earliestNewTimestamp: String

    init(_ url: URL) throws {
        self.url = url
        let snapshot = try Self.open(url)
        let handle = snapshot?.handle
        defer { try? handle?.close() }
        fileID = snapshot?.id
        offset = try handle?.seekToEnd() ?? 0
        let tailLength = Int(min(offset, 256))
        try handle?.seek(toOffset: offset - UInt64(tailLength))
        anchor = try handle?.read(upToCount: tailLength) ?? Data()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        earliestNewTimestamp = formatter.string(from: Date())
    }

    func activeAccount() throws -> UInt64? {
        guard let snapshot = try Self.open(url) else { return nil }
        let handle = snapshot.handle
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var matchingPrefix = snapshot.id == fileID && length >= offset
        if matchingPrefix {
            try handle.seek(toOffset: offset - UInt64(anchor.count))
            matchingPrefix = (try handle.read(upToCount: anchor.count) ?? Data()) == anchor
        }
        let start = matchingPrefix ? offset : 0
        // Fail closed if the log has grown unexpectedly during this attempt.
        guard length - start <= 4 * 1024 * 1024 else { return nil }
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(length - start)) ?? Data()
        guard let end = data.lastIndex(of: 10) else { return nil }
        let text = String(decoding: data[...end], as: UTF8.self)
        if matchingPrefix { return ConnectionLog.activeAccount(in: text) }
        let freshLines = text.components(separatedBy: .newlines).filter { line in
            line.hasPrefix("[") && line.count > 21
                && String(line.dropFirst().prefix(19)) > earliestNewTimestamp
        }
        return ConnectionLog.activeAccount(in: freshLines.joined(separator: "\n"))
    }

    private static func open(_ url: URL) throws -> (handle: FileHandle, id: String)? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            try? handle.close()
            throw SwitchError("无法读取 Steam 登录日志。")
        }
        return (handle, "\(info.st_dev):\(info.st_ino)")
    }
}

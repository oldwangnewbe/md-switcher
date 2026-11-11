import Foundation

struct SteamGameProcess: Equatable {
    let pid: UInt32
    let launchLine: String

    static func current(in log: String) -> Self? {
        var game: Self?
        let app = SteamInstallation.appID
        let start = "AppID \(app) adding PID "
        let stop = "AppID \(app) no longer tracking PID "
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("["), let bracket = line.firstIndex(of: "]") else { continue }
            let event = line[line.index(after: bracket)...].drop(while: \.isWhitespace)
            if event.hasPrefix(start),
               event.localizedCaseInsensitiveContains(#"\masterduel.exe""#),
               let pid = UInt32(event.dropFirst(start.count).prefix(while: \.isNumber)), pid != 0 {
                game = Self(pid: pid, launchLine: String(line))
            } else if event == "Remove \(app) from running list" {
                game = nil
            } else if let running = game, event.hasPrefix(stop),
                      UInt32(event.dropFirst(stop.count).prefix(while: \.isNumber)) == running.pid {
                game = nil
            }
        }
        return game
    }
}

// Polled on the switcher's serial worker. Idle checks only inspect the log file metadata.
final class SteamRoyalFinishMonitor: @unchecked Sendable {
    private struct LogVersion: Equatable {
        let url: URL
        let inode: UInt64
        let size: UInt64
        let modified: timespec

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.url == rhs.url && lhs.inode == rhs.inode && lhs.size == rhs.size &&
                lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }
    }

    private var version: LogVersion?
    private var game: SteamGameProcess?
    private var attemptsRemaining = 0

    func poll(switcher: Switcher, selections: [String: [Int]]) throws -> Bool {
        let url = switcher.installation.gameLog
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size > 0 else { return false }
        let current = LogVersion(url: url, inode: info.st_ino, size: UInt64(info.st_size), modified: info.st_mtimespec)
        if current != version {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let start = current.size > 65_536 ? current.size - 65_536 : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(current.size - start)), let end = data.lastIndex(of: 10)
            else { return false }
            let log = String(decoding: data[...end], as: UTF8.self)
            let next = SteamGameProcess.current(in: log)
            if next != game || current.url != version?.url { attemptsRemaining = 5 }
            game = next
            version = current
        }
        guard let game, attemptsRemaining > 0 else { return false }
        attemptsRemaining -= 1
        do {
            guard let loaded = try switcher.loadSteamRoyalFinish(pid: game.pid, selections: selections) else { return false }
            attemptsRemaining = 0
            return loaded
        } catch {
            attemptsRemaining = 0
            throw error
        }
    }
}

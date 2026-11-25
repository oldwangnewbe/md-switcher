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

    func activeGame(in installation: SteamInstallation) throws -> SteamGameProcess? {
        let url = installation.gameLog
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size > 0 else { return nil }
        let current = LogVersion(url: url, inode: info.st_ino, size: UInt64(info.st_size), modified: info.st_mtimespec)
        if current != version {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let start = current.size > 65_536 ? current.size - 65_536 : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(current.size - start)), let end = data.lastIndex(of: 10)
            else { return nil }
            let log = String(decoding: data[...end], as: UTF8.self)
            let next = SteamGameProcess.current(in: log)
            if next != game || current.url != version?.url { attemptsRemaining = 5 }
            game = next
            version = current
        }
        return game
    }

    func poll(switcher: Switcher, selections: [String: [Int]]) throws -> Bool {
        guard let game = try activeGame(in: switcher.installation), attemptsRemaining > 0 else { return false }
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

// Observe the resource index used by the running game. Repairs must wait until it exits.
final class GameResourceUpdateMonitor: @unchecked Sendable {
    private struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private var seen: [URL: Stamp] = [:]
    private var session: SteamGameProcess?
    private var started: Date?
    private var warned = false

    func poll(game: SteamGameProcess?, resources: ResourceReuse, folders: Set<String>) -> Bool {
        if game != session {
            session = game
            warned = false
            seen = [:]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            started = game.flatMap { formatter.date(from: String($0.launchLine.dropFirst().prefix(19))) }
        }
        guard let started, !warned else { return false }
        for folder in folders.sorted() {
            guard !folder.isEmpty, folder.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let index = resources.root.appendingPathComponent(folder)
                .appendingPathComponent("0000").appendingPathComponent(ResourceReuse.indexPath)
            guard let stamp = Stamp(index), seen[index] != stamp,
                  TimeInterval(stamp.seconds) >= started.timeIntervalSince1970 else { continue }
            guard let mod = try? SkyStrikerMod(resources: resources, account: folder),
                  let needsRepair = try? mod.hasOutdatedDuelResources() else { continue }
            seen[index] = stamp
            if needsRepair {
                warned = true
                return true
            }
        }
        return false
    }
}

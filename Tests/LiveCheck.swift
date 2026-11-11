import Foundation

@main
enum LiveCheck {
    static func main() {
        do {
            let installation = try SteamInstallation.discover()
            let client = CrossOverClient(install: installation)
            let users = try LoginUsers(installation.readLoginFile())
            let preferred = users.accounts.filter(\.preferred)
            let processes = try client.processes()
            let registry = try client.autoLoginUser()
            print("Detected \(users.accounts.count) saved accounts; \(preferred.count) preferred.")
            print("Process query verified. Steam: \(processes.contains("steam.exe")); MD: \(processes.contains("masterduel.exe")).")
            print("Registry preference matches the login file: \(preferred.first?.username == registry).")
            let mode = CommandLine.arguments.dropFirst().first ?? "inspect"
            if mode == "inspect" { return }
            let baseline = CommandLine.arguments.dropFirst(2).first.flatMap(UInt64.init)
            let original = baseline.flatMap { id in users.accounts.first(where: { $0.id == id }) }
                ?? (baseline == nil ? preferred.first : nil)
            guard let original, preferred.count == 1, original.remembered,
                  !processes.contains("masterduel.exe") else {
                throw SwitchError("Live test requires one remembered preferred account and the game to be closed.")
            }
            let switcher = Switcher(installation: installation)
            if mode == "game" {
                try switcher.changeAccount(to: original.id, launchGame: true) { log($0.title) }
                log("Verified Steam logged into the preferred account and Master Duel started.")
                return
            }
            guard mode == "roundtrip",
                  let alternate = users.accounts.first(where: { $0.id != original.id && $0.remembered })
            else { throw SwitchError("Unknown test mode or no second remembered account.") }

            var switchFailure: Error?
            do {
                log("Testing the alternate account in Steam.")
                try switcher.changeAccount(to: alternate.id, launchGame: false, loginTimeout: 55) { log($0.title) }
                log("Alternate account verified in a new Steam session.")
            } catch {
                switchFailure = error
                log("Alternate account test: \(error.localizedDescription)")
            }
            log("Returning Steam to the original account.")
            if switcher.hasPendingRecovery { try switcher.recover() }
            try switcher.changeAccount(to: original.id, launchGame: false, loginTimeout: 55) { log($0.title) }
            log("Original account verified in a new Steam session.")
            if !processes.contains("steam.exe") {
                try client.stop()
                for _ in 0..<25 {
                    let active = try client.processes()
                    if !active.contains("steam.exe") { break }
                    Thread.sleep(forTimeInterval: 1)
                }
                guard try !client.processes().contains("steam.exe") else {
                    throw SwitchError("Steam did not return to its initial closed state.")
                }
                log("Steam returned to its initial closed state.")
            }
            if let switchFailure { throw switchFailure }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }
}

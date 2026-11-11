import Foundation

enum InstallationPaths {
    static func bottleRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let configured = UserDefaults(suiteName: "com.codeweavers.CrossOver")?.string(forKey: "BottleDir")
        let environment = ProcessInfo.processInfo.environment["CX_BOTTLE_PATH"]?
            .split(separator: ":").map(String.init) ?? []
        let paths = environment + [configured].compactMap { $0 }
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            + [home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")]
    }

    static func bottles(in roots: [URL]) -> [URL] {
        var seen = Set<URL>()
        return roots.flatMap(children).filter {
            directory($0.appendingPathComponent("drive_c")) && seen.insert(canonical($0)).inserted
        }
    }

    static func discoverMDPro3(preferred: URL? = nil,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               bottleRoots: [URL]? = nil) -> URL? {
        if let preferred, isMDPro3(preferred) { return canonical(preferred) }
        let drives = bottles(in: bottleRoots ?? self.bottleRoots(home: home)).map {
            $0.appendingPathComponent("drive_c")
        }
        let windowsRoots = drives.flatMap {
            [$0, $0.appendingPathComponent("Program Files"), $0.appendingPathComponent("Program Files (x86)")]
        }
        let localRoots = ["Applications", "Games"].map { home.appendingPathComponent($0) }
        let roots = windowsRoots + localRoots + [URL(fileURLWithPath: "/Applications")]
        let matches = Set((roots + roots.flatMap(children)).filter(isMDPro3).map(canonical))
        return matches.count == 1 ? matches.first : nil
    }

    static func isMDPro3(_ url: URL) -> Bool {
        let fm = FileManager.default
        return directory(url.appendingPathComponent("Picture/Art"))
            && fm.fileExists(atPath: url.appendingPathComponent("Data/locales/zh-CN/cards.cdb").path)
            && fm.fileExists(atPath: url.appendingPathComponent("Data/cards_Lite.json").path)
    }

    static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)) ?? []
    }

    private static func directory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

import CryptoKit
import Foundation

struct ResourceReuse {
    let root: URL

    struct Result {
        let clonedFiles: Int
    }

    static let indexPath = "86/868ffd0e"

    private struct Catalog: Decodable {
        struct Entry: Decodable, Equatable {
            let assetName: String
            let version: String
            let bytes: Int
            let crc: String
        }
        let informations: [Entry]
    }

    private struct FileStamp: Equatable {
        let bytes: Int
        let modified: Date?
    }

    private struct Tree: Equatable {
        var folders = Set<String>()
        var files: [String: FileStamp] = [:]

        var assetFiles: [String: FileStamp] {
            files.filter { path, _ in
                let parts = path.split(separator: "/")
                return parts.count == 2 && parts[0].count == 2 && parts[1].count == 8
                    && parts[1].hasPrefix(parts[0]) && ResourceReuse.isHex(String(parts[1]))
            }
        }
    }

    private struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
    }

    func accountDirectories() throws -> Set<String> {
        try requireDirectory(root)
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return Set(try children.filter { child in
            guard Self.isHex(child.lastPathComponent) else { return false }
            try requireDirectory(child)
            return true
        }.map(\.lastPathComponent))
    }

    func newDirectory(since before: Set<String>) throws -> String? {
        let added = try accountDirectories().subtracting(before)
        guard added.count <= 1 else { throw SwitchError("游戏创建了多个资源目录，无法确认新号目录。") }
        guard let name = added.first else { return nil }
        let url = cacheURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try requireDirectory(url)
        return name
    }

    func existingDirectory(for account: UInt64, excluding reserved: Set<String>,
                           connectionLog: URL, gameLog: URL) throws -> String? {
        let candidates = try accountDirectories().subtracting(reserved)
        guard !candidates.isEmpty,
              let history = GameLaunchHistory(connectionLog: connectionLog, gameLog: gameLog)
        else { return nil }
        var matches: [String] = []
        for name in candidates {
            let cache = cacheURL(name)
            guard FileManager.default.fileExists(atPath: cache.path),
                  let created = try cache.deletingLastPathComponent()
                    .resourceValues(forKeys: [.creationDateKey]).creationDate,
                  let start = history.starts.last(where: { $0.time <= created }),
                  created.timeIntervalSince(start.time) <= 45 else { continue }
            if history.account(at: start) == account {
                matches.append(name)
            }
        }
        guard matches.count <= 1 else {
            throw SwitchError("找到多个可能属于此账号的资源目录，无法自动确认。")
        }
        return matches.first
    }

    func needsPreparation(target: String, source: String) throws -> Bool {
        let known = try accountDirectories()
        guard target != source, known.contains(target), known.contains(source) else {
            throw SwitchError("主账号或小号的资源目录已变化，请核对资源设置。")
        }
        let targetCount = try catalog(cacheURL(target)).informations.count
        if hasBackup(for: target) { return targetCount == 0 }
        let sourceCount = try catalog(cacheURL(source)).informations.count
        guard sourceCount > 0 else { throw SwitchError("请先用主账号完成游戏资源下载。") }
        return targetCount < sourceCount
    }

    func hasBackup(for target: String) -> Bool {
        guard Self.isHex(target), let original = try? readOriginalIdentity(for: target),
              let stored = try? identity(workspaceURL(target).appendingPathComponent("0000"))
        else { return false }
        return original == stored
    }

    func artworkCache(account: String) throws -> URL {
        guard try accountDirectories().contains(account) else { throw SwitchError("找不到主账号资源目录。") }
        return try canonicalDirectory(cacheURL(account))
    }

    func originalArtwork(account: String, path: String) throws -> Data {
        let cache = try artworkCache(account: account)
        guard let entry = try catalog(cache).informations.first(where: { $0.assetName == path }) else {
            throw SwitchError("找不到与这张卡对应的原版游戏资源。")
        }
        return try SkyStrikerMod(resources: self, account: account)
            .originalAsset(path: path, size: entry.bytes, sha256: entry.crc)
    }

    func findMainSource(excluding secondary: Set<String>) throws -> String {
        var candidates: [String] = []
        for name in try accountDirectories().subtracting(secondary) {
            let cache = cacheURL(name)
            guard FileManager.default.fileExists(atPath: cache.appendingPathComponent(Self.indexPath).path)
            else { continue }
            let index = try catalog(cache)
            if index.informations.reduce(Int64(0), { $0 + Int64($1.bytes) }) >= 1_073_741_824 {
                candidates.append(name)
            }
        }
        guard candidates.count == 1, let source = candidates.first else {
            throw SwitchError("无法唯一识别主账号的完整资源。请确认主账号已完成游戏内下载。")
        }
        return source
    }

    func prepare(target: String, source: String, checkGameClosed: () throws -> Void) throws -> Result {
        let known = try accountDirectories()
        guard target != source, known.contains(target), known.contains(source) else {
            throw SwitchError("主账号或新号的资源目录已变化，请核对资源设置。")
        }
        let destination = try canonicalDirectory(cacheURL(target))
        let originalIdentity = try identity(destination)
        try checkGameClosed()
        let workspace = workspaceURL(target)
        let fm = FileManager.default
        let oldTree = try scan(destination)
        let sourceDirectory = try canonicalDirectory(cacheURL(source))
        let sourceTree = try scan(sourceDirectory)
        let mainIndex = try catalog(sourceDirectory)
        let knownAssets = Dictionary(uniqueKeysWithValues: mainIndex.informations.map { ($0.assetName, $0) })
        let mod = try SkyStrikerMod(resources: self, account: source)
        let backups = try mod.backedUpOriginals()
        var sourceAssets = sourceTree.assetFiles
        for path in try mod.addedSummonFiles() {
            if let entry = knownAssets[path] {
                try verifyAssets([entry], in: sourceDirectory, tree: sourceTree)
            } else {
                sourceAssets.removeValue(forKey: path)
            }
        }
        var originals: [String: Data] = [:]
        // Use the original only when it matches the current official index. A
        // game update can replace the live file while leaving an older backup.
        for (path, data) in backups where path != Self.indexPath {
            guard let entry = knownAssets[path] else {
                sourceAssets.removeValue(forKey: path)
                continue
            }
            if sourceAssets[path] != nil, data.count == entry.bytes, digest(data) == entry.crc {
                originals[path] = data
                sourceAssets[path] = FileStamp(bytes: data.count, modified: nil)
            } else {
                try verifyAssets([entry], in: sourceDirectory, tree: sourceTree)
            }
        }
        guard !mainIndex.informations.isEmpty, mainIndex.informations.allSatisfy({
            sourceAssets[$0.assetName]?.bytes == $0.bytes
        }), let indexStamp = sourceAssets[Self.indexPath] else {
            throw SwitchError("主账号的资源索引与磁盘文件不一致，请先用主账号完成更新。")
        }
        let targetIndex = try catalog(destination)
        guard targetIndex.informations.allSatisfy({ knownAssets[$0.assetName] == $0 }) else {
            throw SwitchError("新号和主账号的资源版本不同，请先核对游戏语言及更新。")
        }
        if hasBackup(for: target) {
            guard targetIndex.informations.count < mainIndex.informations.count else {
                throw SwitchError("新号的资源索引已齐全。")
            }
            // Existing installations were prepared by cloning the source. Check
            // their assets before installing an index that describes them.
            try verifyAssets(mainIndex.informations, in: destination, tree: oldTree,
                             matching: sourceAssets.filter { originals[$0.key] == nil })
            try repairIndex(from: sourceDirectory, to: destination, identity: originalIdentity,
                            checkGameClosed: checkGameClosed)
            return Result(clonedFiles: 0)
        }
        if fm.fileExists(atPath: workspace.path) {
            guard try readOriginalIdentity(in: workspace) == originalIdentity else {
                throw SwitchError("新号已有资源备份。请先恢复原资源。")
            }
            let archived = workspace.deletingLastPathComponent()
                .appendingPathComponent(".md-switcher-resource-\(UUID().uuidString)")
            try fm.moveItem(at: workspace, to: archived)
        }
        try verifyAssets(mainIndex.informations.filter { oldTree.files[$0.assetName] != nil },
                         in: destination, tree: oldTree)
        let missing = sourceAssets.filter { $0.key != Self.indexPath && oldTree.files[$0.key] == nil }
        guard !missing.isEmpty || targetIndex.informations.count < mainIndex.informations.count else {
            throw SwitchError("新号的资源和索引已齐全。")
        }

        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        let stagingPath = workspace.appendingPathComponent("0000")
        var installed = false
        defer {
            if !installed { try? fm.removeItem(at: workspace) }
        }
        try JSONEncoder().encode(originalIdentity).write(
            to: workspace.appendingPathComponent("original.json"), options: .atomic
        )
        try fm.createDirectory(at: stagingPath, withIntermediateDirectories: false)
        let staged = try canonicalDirectory(stagingPath)
        let assetFolders = missing.keys.map { String($0.prefix(2)) } + ["86"]
        for folder in oldTree.folders.union(assetFolders).sorted() {
            try fm.createDirectory(at: staged.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for relative in oldTree.files.keys.sorted() where relative != Self.indexPath {
            try clone(destination.appendingPathComponent(relative), into: staged.appendingPathComponent(relative))
        }
        for relative in missing.keys.sorted() {
            let file = staged.appendingPathComponent(relative)
            if let original = originals[relative] {
                try original.write(to: file)
            } else {
                try clone(sourceDirectory.appendingPathComponent(relative), into: file)
            }
        }
        try clone(sourceDirectory.appendingPathComponent(Self.indexPath),
                  into: staged.appendingPathComponent(Self.indexPath))

        let stagedTree = try scan(staged)
        var expected = oldTree.files.merging(missing) { original, _ in original }
        expected[Self.indexPath] = indexStamp
        guard stagedTree.files.mapValues(\.bytes) == expected.mapValues(\.bytes),
              try scan(destination) == oldTree, try identity(destination) == originalIdentity else {
            throw SwitchError("资源校验未通过，原目录仍可使用。")
        }
        try checkGameClosed()
        try swap(staged, destination)
        installed = true
        return Result(clonedFiles: missing.count)
    }

    func restore(target: String, checkGameClosed: () throws -> Void) throws {
        guard try accountDirectories().contains(target), hasBackup(for: target) else {
            throw SwitchError("没有找到可恢复的原资源目录。")
        }
        try checkGameClosed()
        let active = cacheURL(target)
        let workspace = workspaceURL(target)
        let original = workspace.appendingPathComponent("0000")
        try requireDirectory(active)
        try requireDirectory(original)
        try swap(original, active)
    }

    private func cacheURL(_ name: String) -> URL {
        root.appendingPathComponent(name).appendingPathComponent("0000")
    }

    private func workspaceURL(_ target: String) -> URL {
        root.appendingPathComponent(target).appendingPathComponent(".md-switcher-resource-backup")
    }

    private func catalog(_ cache: URL) throws -> Catalog {
        let file = cache.appendingPathComponent(Self.indexPath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Catalog(informations: [])
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let properties = try file.resourceValues(forKeys: keys)
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size <= 32 * 1024 * 1024,
              let value = try? JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file)),
              Set(value.informations.map(\.assetName)).count == value.informations.count,
              value.informations.allSatisfy({ $0.bytes > 0 && $0.crc.count == 64
                  && $0.assetName != Self.indexPath }) else {
            throw SwitchError("游戏资源索引格式异常。")
        }
        return value
    }

    private func verifyAssets(_ entries: [Catalog.Entry], in directory: URL, tree: Tree,
                              matching source: [String: FileStamp] = [:]) throws {
        for entry in entries {
            guard let target = tree.files[entry.assetName], target.bytes == entry.bytes else {
                throw SwitchError("新号资源与主账号的索引不匹配。")
            }
            // Older versions used APFS clones, which retain the source timestamp.
            if source[entry.assetName] == target { continue }
            let file = directory.appendingPathComponent(entry.assetName)
            guard try digest(Data(contentsOf: file, options: .mappedIfSafe)) == entry.crc else {
                throw SwitchError("新号已有不同版本的资源，请先核对游戏语言及更新。")
            }
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repairIndex(from source: URL, to target: URL, identity expectedIdentity: Identity,
                             checkGameClosed: () throws -> Void) throws {
        let fm = FileManager.default
        let active = target.appendingPathComponent(Self.indexPath)
        let previous = try Data(contentsOf: active)
        let temporary = active.deletingLastPathComponent()
            .appendingPathComponent(".md-switcher-index-\(UUID().uuidString)")
        try clone(source.appendingPathComponent(Self.indexPath), into: temporary)
        defer { try? fm.removeItem(at: temporary) }
        try checkGameClosed()
        guard try identity(target) == expectedIdentity, try Data(contentsOf: active) == previous else {
            throw SwitchError("新号资源索引刚刚发生变化，请退出游戏后重试。")
        }
        guard rename(temporary.path, active.path) == 0 else { throw fileError("无法更新资源索引") }
    }

    private func readOriginalIdentity(for target: String) throws -> Identity {
        try readOriginalIdentity(in: workspaceURL(target))
    }

    private func readOriginalIdentity(in workspace: URL) throws -> Identity {
        try requireDirectory(workspace)
        return try JSONDecoder().decode(Identity.self, from: Data(
            contentsOf: workspace.appendingPathComponent("original.json")
        ))
    }

    private func scan(_ directory: URL) throws -> Tree {
        let directory = try canonicalDirectory(directory)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .contentModificationDateKey]
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in readError = error; return false }
        ) else { throw SwitchError("无法读取资源目录。") }
        var tree = Tree()
        let prefix = directory.path + "/"
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: keys)
            guard url.path.hasPrefix(prefix), properties.isSymbolicLink != true else {
                throw SwitchError("资源目录包含链接或异常路径，操作已停止。")
            }
            let relative = String(url.path.dropFirst(prefix.count))
            if properties.isDirectory == true {
                tree.folders.insert(relative)
            } else if properties.isRegularFile == true, let size = properties.fileSize {
                tree.files[relative] = FileStamp(bytes: size, modified: properties.contentModificationDate)
            } else {
                throw SwitchError("资源目录包含无法识别的文件。")
            }
        }
        if let readError { throw readError }
        return tree
    }

    private static func isHex(_ value: String) -> Bool {
        (1...16).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func requireDirectory(_ url: URL) throws {
        _ = try identity(url)
    }

    private func canonicalDirectory(_ url: URL) throws -> URL {
        try requireDirectory(url)
        guard let path = realpath(url.path, nil) else { throw fileError("无法解析资源目录") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SwitchError("资源目录不存在或不是普通文件夹。")
        }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private func clone(_ source: URL, into destination: URL) throws {
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW_ANY)) == 0 else {
            throw fileError("APFS 资源克隆失败")
        }
    }

    private func swap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw fileError("无法切换资源目录")
        }
    }

    private func fileError(_ operation: String) -> SwitchError {
        let reason = String(cString: strerror(errno))
        return SwitchError("\(operation)（\(reason)）。")
    }
}

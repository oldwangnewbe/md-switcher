using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace MDSwitcher;

internal sealed record ResourceSettings(ulong MainAccount, string MainFolder, Dictionary<ulong, string> Accounts);

internal static partial class GameResources
{
    internal const string Index = "86/868ffd0e";

    internal sealed record Entry(
        [property: JsonPropertyName("assetName")] string Name,
        [property: JsonPropertyName("version")] string Version,
        [property: JsonPropertyName("bytes")] long Bytes,
        [property: JsonPropertyName("crc")] string Hash);

    internal sealed record Catalog([property: JsonPropertyName("informations")] Entry[] Items);

    internal static bool IsAccountFolder(string name) => AccountFolder().IsMatch(name);

    public static string Root(Installation install) => Path.Combine(install.Game, "LocalData");

    public static string Identify(Installation install, string folder)
    {
        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        var name = Path.GetFileName(path);
        if (!AccountFolder().IsMatch(name) || Path.GetDirectoryName(path) is not string parent ||
            !Installation.SamePath(parent, Root(install)))
            throw new InvalidDataException("请选择当前游戏 LocalData 里的账号文件夹。");
        _ = ReadIndex(Cache(install, name));
        return name;
    }

    public static int Prepare(Installation install, ResourceSettings settings, ulong account, Func<bool> sessionStillValid,
                              IProgress<string>? progress = null)
    {
        if (settings.MainAccount == account || !settings.Accounts.TryGetValue(account, out var targetFolder)) return 0;
        if (targetFolder.Equals(settings.MainFolder, StringComparison.OrdinalIgnoreCase) ||
            settings.Accounts.Count(pair => pair.Value.Equals(targetFolder, StringComparison.OrdinalIgnoreCase)) != 1)
            throw new InvalidDataException("大号和小号必须各自使用独立的账号资源目录。");

        var source = Cache(install, settings.MainFolder);
        ArtworkFiles.RecoverPending(source, EnsureIdle);
        var targetLocation = CacheLocation(install, targetFolder);
        if (SharedCache.IsLinkedTo(targetLocation, source))
        {
            if (!File.Exists(AssetPath(source, Index))) throw new IOException("大号缓存缺少资源索引。");
            return 0;
        }
        var target = Cache(install, targetFolder);
        var from = ReadIndex(source);
        var to = ReadIndex(target);
        var originals = from.Items.ToDictionary(entry => entry.Name, StringComparer.OrdinalIgnoreCase);
        if (from.Items.Length == 0)
            throw new InvalidDataException("主账号尚无可复用的游戏资源。");
        if (to.Items.Length > from.Items.Length) return 0;
        if (to.Items.Any(item => !originals.TryGetValue(item.Name, out var match) || match != item))
        {
            if (to.Items.Length == from.Items.Length) return 0;
            throw new InvalidDataException("主账号与小号的资源版本不匹配，请检查游戏更新和语言。");
        }

        var missing = from.Items.Any(item => !File.Exists(AssetPath(target, item.Name)));
        if (!missing && to.Items.Length == from.Items.Length) return 0;

        EnsureIdle();
        var sourceVolume = ResourceVolume.Read(source);
        var destinationVolume = ResourceVolume.Read(target);
        var canClone = sourceVolume.CanCloneTo(destinationVolume);
        var useHardLinks = !canClone && sourceVolume.CanHardLinkTo(destinationVolume);
        if (!canClone && !useHardLinks && missing)
            throw new IOException("主号和小号的资源须位于同一个 NTFS 或支持块克隆的 ReFS 卷。可用「仅切换 Steam」先登录账号。");
        if (missing)
            progress?.Report(useHardLinks ? "正在核对原版资源并建立 NTFS 硬链接…" : "正在核对原版资源并共享 ReFS 数据块…");
        var poll = Stopwatch.StartNew();
        var buffer = new byte[256 * 1024];
        var added = 0;
        var processed = 0;
        long bytesShared = 0;
        long bytesWritten = 0;
        foreach (var item in from.Items)
        {
            ReportProgress();
            var destination = AssetPath(target, item.Name);
            if (File.Exists(destination))
            {
                if (!Matches(destination, item) && ArtworkFiles.OriginalWhenModified(target, item) is null)
                    throw new IOException($"小号的资源 {item.Name} 已存在但内容不同。");
                processed++;
                continue;
            }

            if (!canClone && !useHardLinks) throw new IOException("小号资源刚刚发生变化，请重新核对。");
            var input = ArtworkFiles.OriginalWhenModified(source, item) ?? AssetPath(source, item.Name);
            if (!File.Exists(input)) throw new IOException($"主账号的资源 {item.Name} 尚未下载。");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var stage = Path.Combine(Path.GetDirectoryName(destination)!, $".md-{Guid.NewGuid():N}.tmp");
            try
            {
                ShareVerified(input, stage, item);
                ReportProgress();
                File.Move(stage, destination);
                added++;
                processed++;
            }
            finally { File.Delete(stage); }
        }

        EnsureIdle();
        progress?.Report("资源文件已核对，正在更新小号资源索引…");
        var index = AssetPath(target, Index);
        var backup = Path.Combine(Path.GetDirectoryName(target)!, ".md-switcher-original-index");
        if (!File.Exists(backup)) File.Copy(index, backup);
        var latestSource = ReadIndex(source);
        if (!latestSource.Items.SequenceEqual(from.Items) || !ReadIndex(target).Items.SequenceEqual(to.Items))
            throw new IOException("游戏资源索引在复用期间发生了变化，请重试。");
        var updated = File.ReadAllText(AssetPath(source, Index));
        EnsureIdle();
        SteamSession.AtomicWrite(index, updated);
        return added;

        void ReportProgress()
        {
            if (poll.ElapsedMilliseconds < 1000) return;
            EnsureIdle();
            progress?.Report($"已核对 {processed:N0} / {from.Items.Length:N0} 个文件，共享 {bytesShared / 1048576d:N1} MB，实际写入 {bytesWritten / 1048576d:N1} MB。");
            poll.Restart();
        }

        void ShareVerified(string input, string stage, Entry item)
        {
            using var reader = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.Read,
                bufferSize: 1, FileOptions.SequentialScan);
            if (reader.Length != item.Bytes) throw SourceMismatch(item);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long validated = 0;
            int count;
            while ((count = reader.Read(buffer)) != 0)
            {
                validated += count;
                if (validated > item.Bytes) throw SourceMismatch(item);
                hash.AppendData(buffer, 0, count);
                ReportProgress();
            }
            if (validated != item.Bytes || !Convert.ToHexString(hash.GetHashAndReset()).Equals(item.Hash, StringComparison.OrdinalIgnoreCase))
                throw SourceMismatch(item);

            if (useHardLinks)
            {
                ResourceVolume.HardLink(input, stage);
                bytesShared += item.Bytes;
                return;
            }

            using var writer = new FileStream(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None, bufferSize: 1);
            var shared = sourceVolume.CloneAlignedBlocks(reader, writer, item.Bytes, ReportProgress);
            bytesShared += shared;
            // Only a partial cluster at the end needs a physical copy.
            reader.Position = writer.Position = shared;
            while ((count = reader.Read(buffer)) != 0)
            {
                writer.Write(buffer, 0, count);
                bytesWritten += count;
            }
            if (writer.Length != item.Bytes) throw SourceMismatch(item);
        }

        void EnsureIdle()
        {
            if (!sessionStillValid() || SteamSession.GameRunning())
                throw new InvalidOperationException("Steam 账号已变化或游戏正在运行，已暂停复用。");
        }
    }

    private static IOException SourceMismatch(Entry item) => new($"主账号的资源 {item.Name} 与游戏索引不匹配。");

    internal static string Cache(Installation install, string name)
    {
        var cache = CacheLocation(install, name);
        RequireDirectory(cache);
        return cache;
    }

    internal static string CacheLocation(Installation install, string name)
    {
        if (!AccountFolder().IsMatch(name)) throw new InvalidDataException("账号资源文件夹格式异常。");
        var root = Root(install);
        var account = Path.Combine(root, name);
        RequireDirectory(root);
        RequireDirectory(account);
        return Path.Combine(account, "0000");
    }

    private static void RequireDirectory(string path)
    {
        if (!Directory.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("账号资源目录缺失或指向链接。请先在游戏内完成首次初始化，或在账号详情中恢复原缓存。");
    }

    internal static Catalog ReadIndex(string cache)
    {
        var file = AssetPath(cache, Index);
        var index = JsonSerializer.Deserialize<Catalog>(File.ReadAllText(file));
        if (index?.Items is null || index.Items.Any(entry => entry is null ||
                !AssetName().IsMatch(entry.Name ?? "") || entry.Name == Index ||
                !entry.Name.AsSpan(0, 2).SequenceEqual(entry.Name.AsSpan(3, 2)) ||
                entry.Version is null || !Sha256().IsMatch(entry.Hash ?? "") || entry.Bytes <= 0)
            || index.Items.Select(entry => entry.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != index.Items.Length)
            throw new InvalidDataException("游戏资源索引格式异常。");
        return index;
    }

    internal static string AssetPath(string cache, string name)
    {
        if (!AssetName().IsMatch(name) || !name.AsSpan(0, 2).SequenceEqual(name.AsSpan(3, 2)))
            throw new InvalidDataException("游戏资源路径格式异常。");
        var folder = Path.Combine(cache, name[..2]);
        var file = Path.Combine(folder, name[3..]);
        if (Directory.Exists(folder) && (File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0 ||
            File.Exists(file) && (File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("游戏资源包含文件链接，已停止复用。");
        return file;
    }

    internal static bool Matches(string file, Entry item)
    {
        using var stream = File.OpenRead(file);
        return stream.Length == item.Bytes && Convert.ToHexString(SHA256.HashData(stream)).Equals(
            item.Hash, StringComparison.OrdinalIgnoreCase);
    }

    [GeneratedRegex(@"\A[0-9a-fA-F]{1,16}\z")]
    private static partial Regex AccountFolder();

    [GeneratedRegex(@"\A[0-9a-f]{2}/[0-9a-f]{8}\z")]
    private static partial Regex AssetName();

    [GeneratedRegex(@"\A[0-9a-fA-F]{64}\z")]
    private static partial Regex Sha256();
}

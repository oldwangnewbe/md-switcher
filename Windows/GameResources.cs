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

    public static int Prepare(Installation install, ResourceSettings settings, ulong account, Func<bool> sessionStillValid)
    {
        if (settings.MainAccount == account || !settings.Accounts.TryGetValue(account, out var targetFolder)) return 0;
        if (targetFolder.Equals(settings.MainFolder, StringComparison.OrdinalIgnoreCase) ||
            settings.Accounts.Count(pair => pair.Value.Equals(targetFolder, StringComparison.OrdinalIgnoreCase)) != 1)
            throw new InvalidDataException("大号和小号必须各自使用独立的账号资源目录。");

        var source = Cache(install, settings.MainFolder);
        var target = Cache(install, targetFolder);
        var from = ReadIndex(source);
        var to = ReadIndex(target);
        var originals = from.Items.ToDictionary(entry => entry.Name, StringComparer.OrdinalIgnoreCase);
        if (from.Items.Length == 0)
            throw new InvalidDataException("主账号尚无可复用的游戏资源。");
        if (to.Items.Length >= from.Items.Length) return 0;
        if (to.Items.Any(item => !originals.TryGetValue(item.Name, out var match) || match != item))
            throw new InvalidDataException("主账号与小号的资源版本不匹配，请检查游戏更新和语言。");

        EnsureIdle();
        var poll = Stopwatch.StartNew();
        var copied = 0;
        foreach (var item in from.Items)
        {
            if (poll.ElapsedMilliseconds >= 1000)
            {
                EnsureIdle();
                poll.Restart();
            }
            var destination = AssetPath(target, item.Name);
            if (File.Exists(destination))
            {
                if (!Matches(destination, item) && ArtworkFiles.OriginalWhenModified(target, item) is null)
                    throw new IOException($"小号的资源 {item.Name} 已存在但内容不同。");
                continue;
            }

            var input = ArtworkFiles.OriginalWhenModified(source, item) ?? AssetPath(source, item.Name);
            if (!File.Exists(input)) throw new IOException($"主账号的资源 {item.Name} 尚未下载。");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var stage = Path.Combine(Path.GetDirectoryName(destination)!, $".md-{Guid.NewGuid():N}.tmp");
            try
            {
                File.Copy(input, stage);
                if (!Matches(stage, item)) throw new IOException($"主账号的资源 {item.Name} 与游戏索引不匹配。");
                File.Move(stage, destination);
                copied++;
            }
            finally { File.Delete(stage); }
        }

        EnsureIdle();
        var index = AssetPath(target, Index);
        var backup = Path.Combine(Path.GetDirectoryName(target)!, ".md-switcher-original-index");
        if (!File.Exists(backup)) File.Copy(index, backup);
        var latestSource = ReadIndex(source);
        if (!latestSource.Items.SequenceEqual(from.Items) || !ReadIndex(target).Items.SequenceEqual(to.Items))
            throw new IOException("游戏资源索引在复用期间发生了变化，请重试。");
        var updated = File.ReadAllText(AssetPath(source, Index));
        EnsureIdle();
        SteamSession.AtomicWrite(index, updated);
        return copied;

        void EnsureIdle()
        {
            if (!sessionStillValid() || SteamSession.GameRunning())
                throw new InvalidOperationException("Steam 账号已变化或游戏正在运行，已暂停复用。");
        }
    }

    internal static string Cache(Installation install, string name)
    {
        if (!AccountFolder().IsMatch(name)) throw new InvalidDataException("账号资源文件夹格式异常。");
        var root = Root(install);
        var account = Path.Combine(root, name);
        var cache = Path.Combine(account, "0000");
        foreach (var path in new[] { root, account, cache })
            if (!Directory.Exists(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("账号资源目录缺失或指向链接。请先在游戏内完成首次初始化。");
        return cache;
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

using System.Security.Cryptography;
using System.Text.Json;

namespace MDSwitcher;

internal static class ArtworkFiles
{
    private sealed record EditHistory(Dictionary<string, int> Variants);

    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    public static int? AppliedVariant(string cache, GameResources.Entry entry)
    {
        var asset = GameResources.AssetPath(cache, entry.Name);
        var history = ReadHistory(cache, entry);
        return history is not null && File.Exists(asset)
            && history.Variants.TryGetValue(HashFile(asset), out var id) ? id : null;
    }

    public static string? OriginalWhenModified(string cache, GameResources.Entry entry)
    {
        var history = ReadHistory(cache, entry);
        if (history is null) return null;
        var live = GameResources.AssetPath(cache, entry.Name);
        if (!File.Exists(live) || !history.Variants.ContainsKey(HashFile(live))) return null;
        var backup = StatePath(cache, entry, ".original");
        return File.Exists(backup) && GameResources.Matches(backup, entry) ? backup : null;
    }

    public static byte[] ReadOriginal(string cache, GameResources.Entry entry)
    {
        var path = GameResources.AssetPath(cache, entry.Name);
        if (!File.Exists(path)) throw new IOException("这张卡的原版资源尚未下载。请先进入游戏查看该卡。");
        var bytes = File.ReadAllBytes(path);
        if (IsOriginal(bytes, entry)) return bytes;
        var history = ReadHistory(cache, entry);
        var backup = StatePath(cache, entry, ".original");
        if (history is not null && history.Variants.ContainsKey(Hash(bytes)) && File.Exists(backup))
        {
            var original = File.ReadAllBytes(backup);
            if (IsOriginal(original, entry)) return original;
        }
        throw new IOException("当前卡图与游戏索引不匹配，可能已更新或被其他 Mod 修改。请先核对游戏资源。");
    }

    public static bool Apply(string cache, GameResources.Entry entry, byte[] original, byte[]? patch,
                             int? variant, Action ensureGameClosed)
    {
        if (!IsOriginal(original, entry))
            throw new InvalidDataException("原卡图未通过校验。");
        ensureGameClosed();
        var asset = GameResources.AssetPath(cache, entry.Name);
        var current = HashFile(asset);
        var desired = patch is null ? entry.Hash.ToUpperInvariant() : Hash(patch);
        var history = ReadHistory(cache, entry) ?? new([]);
        if (current == desired && (patch is null || history.Variants.ContainsKey(current))) return false;
        if (!current.Equals(entry.Hash, StringComparison.OrdinalIgnoreCase) && !history.Variants.ContainsKey(current))
            throw new IOException("卡图已被游戏或其他程序修改，请重新核对资源。");

        if (patch is not null)
        {
            if (variant is null) throw new InvalidDataException("异画编号缺失。");
            var backup = StatePath(cache, entry, ".original");
            if (!File.Exists(backup) || !GameResources.Matches(backup, entry))
                SteamSession.AtomicWrite(backup, original);
            // Record both old and new hashes before replacing. Either state is
            // recoverable if the process stops between these two writes.
            history.Variants[desired] = variant.Value;
            SteamSession.AtomicWrite(StatePath(cache, entry, ".json"), JsonSerializer.Serialize(history));
        }
        ensureGameClosed();
        if (HashFile(asset) != current) throw new IOException("卡图刚刚被其他程序修改，请重试。");
        SteamSession.AtomicWrite(asset, patch ?? original);
        return true;
    }

    private static bool IsOriginal(byte[] bytes, GameResources.Entry entry) =>
        bytes.LongLength == entry.Bytes && Hash(bytes).Equals(entry.Hash, StringComparison.OrdinalIgnoreCase);

    private static EditHistory? ReadHistory(string cache, GameResources.Entry entry)
    {
        var directory = Path.Combine(Path.GetDirectoryName(cache)!, ".md-switcher-artwork");
        if (!Directory.Exists(directory)) return null;
        var file = StatePath(cache, entry, ".json");
        return File.Exists(file) ? JsonSerializer.Deserialize<EditHistory>(File.ReadAllText(file)) : null;
    }

    private static string StatePath(string cache, GameResources.Entry entry, string extension)
    {
        _ = GameResources.AssetPath(cache, entry.Name);
        var account = Path.GetDirectoryName(cache)!;
        var root = Path.Combine(account, ".md-switcher-artwork");
        var folder = Path.Combine(root, entry.Name[3..]);
        var file = Path.Combine(folder, entry.Hash.ToUpperInvariant() + extension);
        foreach (var path in new[] { root, folder, file })
            if ((Directory.Exists(path) || File.Exists(path)) &&
                (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("异画备份路径包含链接，已停止操作。");
        return file;
    }
}

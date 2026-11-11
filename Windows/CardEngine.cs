using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MDSwitcher;

internal sealed record CardVariant(int Id, string File);
internal sealed record Card(string Id, int? Cid, string? MasterName, string? ProName, int[] Codes,
                            int[] MasterIDs, CardVariant[] Variants, string? Path, string[] Series)
{
    public string Name => MasterName ?? ProName ?? Id;
    public bool Replaceable => Cid.HasValue && Path is not null && Variants.Length > 0;
}

internal sealed partial class CardEngine(string state, string pro)
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    private const string CacheVersion = "win-card-1";
    private static readonly string EnginePath = Path.Combine(AppContext.BaseDirectory, "CardEngine");
    private sealed record SavedIndex(string Fingerprint, Card[] Cards);
    private sealed record GeneratedPatch(string Path, string OriginalSHA256, ArtworkInput SourceArtwork, PatchedVariant[] Variants);
    private sealed record ArtworkInput(int Format, int Cid, string Sha256);
    private sealed record PatchedVariant(int Id, string Sha256);

    public Card[] LoadCards(string cache)
    {
        var fingerprint = Fingerprint(cache);
        var index = Path.Combine(state, "card-index-windows.json");
        if (File.Exists(index))
        {
            try
            {
                var saved = JsonSerializer.Deserialize<SavedIndex>(File.ReadAllText(index), Json);
                if (saved?.Fingerprint == fingerprint && saved.Cards.Length > 0) return saved.Cards;
            }
            catch (JsonException) { }
        }

        return InWorkspace(work =>
        {
            var output = Path.Combine(work, "cards.json");
            Run(work, "index", cache, pro, output);
            var cards = JsonSerializer.Deserialize<Card[]>(File.ReadAllText(output), Json)
                ?? throw new InvalidDataException("无法读取卡片索引。");
            if (cards.Length == 0 || Fingerprint(cache) != fingerprint)
                throw new InvalidDataException("卡库在索引过程中发生了变化，请重试。");
            SteamSession.AtomicWrite(index, JsonSerializer.Serialize(new SavedIndex(fingerprint, cards)));
            return cards;
        });
    }

    public string ArtworkPath(CardVariant variant)
    {
        if (!ArtworkFilename().IsMatch(variant.File) ||
            !int.TryParse(Path.GetFileNameWithoutExtension(variant.File), out var id) || id != variant.Id)
            throw new InvalidDataException("异画文件名无效。");
        return Path.Combine(pro, "Picture", "Art", variant.File);
    }

    public byte[] MakePatch(Card card, CardVariant variant, byte[] original)
    {
        if (card.Cid is not int cid || card.Path is null || !card.Variants.Contains(variant))
            throw new InvalidDataException("该异画没有匹配的 Master Duel 卡图。");
        var image = File.ReadAllBytes(ArtworkPath(variant));
        var originalHash = ArtworkFiles.Hash(original);
        var sourceHash = ArtworkFiles.Hash(image);
        var key = $"{CacheVersion}-{cid}-{variant.Id}-{originalHash}-{sourceHash}";
        var destination = Path.Combine(state, "card-art-library", key);
        if (Directory.Exists(destination))
        {
            try { return Check(destination); }
            catch (Exception error) when (error is IOException or JsonException or InvalidDataException) { }
        }
        return InWorkspace(work =>
        {
            var input = Path.Combine(work, "original");
            var art = Path.Combine(work, variant.File);
            var output = Path.Combine(work, "pack");
            File.WriteAllBytes(input, original);
            File.WriteAllBytes(art, image);
            Directory.CreateDirectory(output);
            Run(work, "patch", input, art, cid.ToString(), card.Path, variant.Id.ToString(), card.Name, output);
            var patch = Check(output);
            Directory.CreateDirectory(destination);
            SteamSession.AtomicWrite(Path.Combine(destination, $"{variant.Id}.bundle"), patch);
            SteamSession.AtomicWrite(Path.Combine(destination, "manifest.json"), File.ReadAllBytes(Path.Combine(output, "manifest.json")));
            return patch;
        });

        byte[] Check(string directory)
        {
            var manifest = JsonSerializer.Deserialize<GeneratedPatch[]>(File.ReadAllText(Path.Combine(directory, "manifest.json")), Json);
            if (manifest is not [{ } item] || item.Path != card.Path ||
                !originalHash.Equals(item.OriginalSHA256, StringComparison.OrdinalIgnoreCase) ||
                item.SourceArtwork is not { Format: 1 } source || source.Cid != cid ||
                !sourceHash.Equals(source.Sha256, StringComparison.OrdinalIgnoreCase) ||
                item.Variants is not [{ } selected] || selected.Id != variant.Id)
                throw new InvalidDataException("异画缓存与当前卡图不匹配。");
            var bundle = File.ReadAllBytes(Path.Combine(directory, $"{variant.Id}.bundle"));
            if (!bundle.AsSpan().StartsWith("UnityFS\0"u8) ||
                !ArtworkFiles.Hash(bundle).Equals(selected.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("异画资源未通过校验。");
            return bundle;
        }
    }

    private string Fingerprint(string cache)
    {
        if (!Installation.IsMDPro3(pro)) throw new IOException("MDPro3 目录已移动，请在设置里重新选择。");
        var zh = Path.Combine(pro, "Data", "locales", "zh-CN");
        var files = new[] { GameResources.AssetPath(cache, GameResources.Index), Path.Combine(zh, "cards.cdb"),
            Path.Combine(zh, "cards.cdb-wal"), Path.Combine(zh, "strings.conf"), Path.Combine(pro, "Data", "cards_Lite.json") };
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Add(CacheVersion); Add(cache); Add(pro);
        foreach (var file in files)
        {
            if (!File.Exists(file)) { Add("-"); continue; }
            using var stream = File.OpenRead(file);
            hash.AppendData(SHA256.HashData(stream));
        }
        foreach (var file in Directory.EnumerateFiles(Path.Combine(pro, "Picture", "Art")).Order(StringComparer.Ordinal))
        {
            if (!ArtworkFilename().IsMatch(Path.GetFileName(file))) continue;
            var info = new FileInfo(file);
            Add($"{info.Name}:{info.Length}:{info.LastWriteTimeUtc.Ticks}");
        }
        foreach (var folder in Directory.EnumerateDirectories(cache).Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileName(folder);
            if (name.Length != 2 || name.Any(character => !Uri.IsHexDigit(character))) continue;
            foreach (var file in Directory.EnumerateFiles(folder).Select(Path.GetFileName).Order(StringComparer.Ordinal))
                if (file is not null && file.Length == 8 && file.StartsWith(name, StringComparison.Ordinal)) Add(file);
        }
        return Convert.ToHexString(hash.GetHashAndReset());

        void Add(string value) => hash.AppendData(Encoding.UTF8.GetBytes(value + "\0"));
    }

    private T InWorkspace<T>(Func<string, T> action)
    {
        var work = Directory.CreateTempSubdirectory("md-card-").FullName;
        try { return action(work); }
        finally { Directory.Delete(work, recursive: true); }
    }

    private static void Run(string work, params string[] arguments)
    {
        var python = Path.Combine(EnginePath, "python.exe");
        var script = Path.Combine(EnginePath, "card_search.py");
        if (!File.Exists(python) || !File.Exists(script))
            throw new IOException("找不到 CardEngine。请解压整个测试包，并把文件夹留在程序旁边。");
        var start = new ProcessStartInfo(python)
        {
            WorkingDirectory = work, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true,
        };
        foreach (var value in new[] { "-B", "-X", "utf8", script }.Concat(arguments)) start.ArgumentList.Add(value);
        using var process = Process.Start(start) ?? throw new IOException("无法启动本地卡图组件。");
        var error = process.StandardError.ReadToEndAsync();
        _ = process.StandardOutput.ReadToEndAsync();
        if (!process.WaitForExit(180_000))
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
            throw new TimeoutException("处理卡图超时，请重试。");
        }
        if (process.ExitCode == 0) return;
        var reason = error.GetAwaiter().GetResult().Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim();
        throw new IOException($"卡图处理失败。{reason}");
    }

    [GeneratedRegex(@"\A[0-9]+\.(jpg|jpeg|png)\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ArtworkFilename();
}

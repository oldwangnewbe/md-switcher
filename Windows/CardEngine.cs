using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MDSwitcher;

internal sealed record OverFrameSource(string File, string? Gate);
internal sealed record CardVariant(int Id, string File, OverFrameSource? OverFrame = null)
{
    public bool CanApply => OverFrame is null || OverFrame.Gate is not null;
}
internal sealed record Card(string Id, int? Cid, string? MasterName, string? ProName, int[] Codes,
                            int[] MasterIDs, CardVariant[] Variants, string? Path, string[] Series,
                            string? PreviewFile = null, string? OriginalPreviewPath = null, int? OriginalArtworkID = null,
                            Performance[]? Performances = null)
{
    public string Name => MasterName ?? ProName ?? Id;
    public bool Replaceable => Cid.HasValue && Path is not null && Variants.Any(variant => variant.CanApply);
    public Performance[] MatchingPerformances(int artworkId) =>
        (Performances ?? []).Where(option => option.ArtworkID == artworkId).ToArray();
}

internal sealed partial class CardEngine(string state, string pro)
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    private const string CacheVersion = "win-card-4";
    private static readonly string EnginePath = Path.Combine(AppContext.BaseDirectory, "CardEngine");
    private sealed record SavedIndex(string Fingerprint, Card[] Cards);
    private sealed record GeneratedPatch(string Path, string OriginalSHA256, ArtworkInput SourceArtwork,
                                         PatchedVariant[] Variants, OverFrameRegistration? OverFrame);
    private sealed record OverFrameRegistration(int CardID, string Gate);
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
            var indexEntries = GameResources.ReadIndex(cache).Items.ToDictionary(item => item.Name);
            var metadata = new[] { Performance.Catalog, Performance.Trigger };
            string[] args = ["index", cache, pro, output, "--over-frame"];
            if (metadata.All(path => indexEntries.ContainsKey(path) && File.Exists(GameResources.AssetPath(cache, path))))
            {
                var originals = metadata.Select(path =>
                {
                    var file = Path.Combine(work, path[3..]);
                    File.WriteAllBytes(file, ArtworkFiles.ReadOriginal(cache, indexEntries[path]));
                    return file;
                }).ToArray();
                args = [.. args, "--performance-metadata", .. originals];
            }
            Run(work, args);
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
        var name = variant.OverFrame?.File ?? variant.File;
        if (!ArtworkFilename().IsMatch(name) ||
            !int.TryParse(Path.GetFileNameWithoutExtension(name), out var id) || id != variant.Id)
            throw new InvalidDataException("异画文件名无效。");
        return Path.Combine(pro, "Picture", variant.OverFrame is null ? "Art" : "OverFrame", name);
    }

    public string? OriginalPath(Card card)
    {
        var parts = card.OriginalPreviewPath?.Split('/');
        return parts is ["Art" or "OverFrame", var name] && ArtworkFilename().IsMatch(name)
            ? Path.Combine(pro, "Picture", parts[0], name) : null;
    }

    public string? ThumbnailPath(Card card) => card.PreviewFile is string name && ArtworkFilename().IsMatch(name)
        ? Path.Combine(pro, "Picture", "Art", name) : null;

    public byte[] MakePatch(Card card, CardVariant variant, byte[] original)
    {
        if (card.Cid is not int cid || card.Path is null || !variant.CanApply || !card.Variants.Contains(variant))
            throw new InvalidDataException("该异画没有匹配的 Master Duel 卡图。");
        var artworkPath = ArtworkPath(variant);
        var image = File.ReadAllBytes(artworkPath);
        var overFrame = variant.OverFrame?.Gate is string gate ? new OverFrameRegistration(cid, gate) : null;
        var originalHash = ArtworkFiles.Hash(original);
        var sourceHash = ArtworkFiles.Hash(image);
        var key = $"{CacheVersion}-{cid}-{variant.Id}-{(overFrame is null ? "art" : "overframe")}-{originalHash}-{sourceHash}";
        var destination = Path.Combine(state, "card-art-library", key);
        if (Directory.Exists(destination))
        {
            try { return Check(destination); }
            catch (Exception error) when (error is IOException or JsonException or InvalidDataException) { }
        }
        return InWorkspace(work =>
        {
            var input = Path.Combine(work, "original");
            var art = Path.Combine(work, Path.GetFileName(artworkPath));
            var output = Path.Combine(work, "pack");
            File.WriteAllBytes(input, original);
            File.WriteAllBytes(art, image);
            Directory.CreateDirectory(output);
            string[] args = ["patch", input, art, cid.ToString(), card.Path, variant.Id.ToString(), card.Name, output];
            if (overFrame is not null) args = [.. args, "--over-frame-gate", overFrame.Gate];
            Run(work, args);
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
                item.SourceArtwork is not { } source || source.Format != (overFrame is null ? 1 : 2) ||
                source.Cid != cid || item.OverFrame != overFrame ||
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

    public byte[] RewriteOverFrameGate(byte[] original, IEnumerable<int> cardIds) => InWorkspace(work =>
    {
        var input = Path.Combine(work, "original");
        var output = Path.Combine(work, "registration");
        File.WriteAllBytes(input, original);
        Run(work, ["over-frame-gate", input, output, .. cardIds.Distinct().Order().Select(id => id.ToString())]);
        var result = File.ReadAllBytes(output);
        if (!result.AsSpan().StartsWith("UnityFS\0"u8))
            throw new InvalidDataException("超框登记资源格式异常。");
        return result;
    });

    private sealed record PerformanceBundle(uint Id, string Sha256);
    private sealed record PerformanceAsset(string Path, string? OriginalSHA256, PerformanceBundle[] Variants);
    internal sealed record PerformancePatch(string Path, string? OriginalSHA256, byte[] Data);

    public PerformancePatch[] MakePerformancePack(string cache, Performance[] selected,
        IReadOnlyDictionary<string, GameResources.Entry> index, IEnumerable<string> previousPaths) => InWorkspace(work =>
    {
        var originals = Path.Combine(work, "originals");
        var output = Path.Combine(work, "pack");
        Directory.CreateDirectory(originals);
        Directory.CreateDirectory(output);
        var targets = selected.Where(option => !option.AddsSummon).SelectMany(option => option.Paths()).ToHashSet();
        targets.Add(Performance.Catalog);
        if (selected.Any(option => option.AddsSummon)) targets.Add(Performance.Trigger);
        var inputs = targets.Union(previousPaths.Where(index.ContainsKey)).ToHashSet();
        if (selected.Any(option => option.Donor is null))
            inputs.UnionWith(Performance.SummonPaths(13668));
        foreach (var path in inputs)
        {
            if (!index.TryGetValue(path, out var entry))
                throw new IOException("当前账号缺少演出资源，请先完成游戏内下载。");
            File.WriteAllBytes(Path.Combine(originals, path[3..]), ArtworkFiles.ReadOriginal(cache, entry));
        }
        Run(work, ["summon", cache, originals, output, pro, .. selected.OrderBy(option => option.Cid).Select(option => option.Spec)]);
        var manifest = JsonSerializer.Deserialize<PerformanceAsset[]>(File.ReadAllText(Path.Combine(output, "manifest.json")), Json)
            ?? throw new InvalidDataException("无法读取演出包。");
        var paths = new HashSet<string>();
        var patches = new List<PerformancePatch>();
        foreach (var asset in manifest)
        {
            _ = GameResources.AssetPath(cache, asset.Path);
            if (!paths.Add(asset.Path) || asset.Variants is not [var variant] ||
                index.ContainsKey(asset.Path) != targets.Contains(asset.Path) ||
                (asset.OriginalSHA256 is not null) != targets.Contains(asset.Path))
                throw new InvalidDataException("演出包的资源路径或备份范围不匹配。");
            if (asset.OriginalSHA256 is string digest && !digest.Equals(index[asset.Path].Hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("演出包的原始资源校验失败。");
            if (variant.Id != Convert.ToUInt32(asset.Path[3..], 16))
                throw new InvalidDataException("演出包的资源编号与文件路径不匹配。");
            var bytes = File.ReadAllBytes(Path.Combine(output, $"{variant.Id}.bundle"));
            if (!ArtworkFiles.Hash(bytes).Equals(variant.Sha256, StringComparison.OrdinalIgnoreCase) ||
                (asset.Path != Performance.Catalog && !bytes.AsSpan().StartsWith("UnityFS\0"u8)))
                throw new InvalidDataException("演出资源未通过校验。");
            patches.Add(new(asset.Path, asset.OriginalSHA256, bytes));
        }
        if (!paths.IsSupersetOf(targets.Concat(selected.Where(option => option.AddsSummon).SelectMany(option => option.Paths()))))
            throw new InvalidDataException("演出包缺少必要资源。");
        return patches.ToArray();
    });

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
        foreach (var name in new[] { "Art", "OverFrame" })
        {
            var folder = Path.Combine(pro, "Picture", name);
            Add(name);
            if (!Directory.Exists(folder)) continue;
            foreach (var file in Directory.EnumerateFiles(folder).Order(StringComparer.Ordinal))
            {
                if (!ArtworkFilename().IsMatch(Path.GetFileName(file))) continue;
                var info = new FileInfo(file);
                Add($"{info.Name}:{info.Length}:{info.LastWriteTimeUtc.Ticks}");
            }
        }
        foreach (var folder in Directory.EnumerateDirectories(cache).Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileName(folder);
            if (name.Length != 2 || name.Any(character => !Uri.IsHexDigit(character))) continue;
            foreach (var file in Directory.EnumerateFiles(folder).Select(Path.GetFileName).Order(StringComparer.Ordinal))
                if (file is not null && file.Length == 8 && file.StartsWith(name, StringComparison.Ordinal)) Add(file);
        }
        var cutins = Path.Combine(pro, "MDPro3_Data", "StandaloneWindows64", "MonsterCutin2");
        if (Directory.Exists(cutins))
            foreach (var file in Directory.EnumerateFiles(cutins).Order(StringComparer.Ordinal))
            {
                var info = new FileInfo(file);
                if (int.TryParse(info.Name, out _)) Add($"{info.Name}:{info.Length}:{info.LastWriteTimeUtc.Ticks}");
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

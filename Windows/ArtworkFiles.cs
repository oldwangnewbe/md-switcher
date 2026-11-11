using System.Security.Cryptography;
using System.Text.Json;

namespace MDSwitcher;

internal sealed record ArtworkChoice(Card Card, CardVariant? Variant);

internal static class ArtworkFiles
{
    private sealed record EditHistory(Dictionary<string, int> Variants);
    private sealed record Registration(string Gate, Dictionary<string, int> Cards);
    private sealed record Change(string Asset, int Slot, string Before, string After);
    private sealed record EditState(Registration? OverFrame = null, Change[]? Pending = null);

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

    public static void ApplySelection(string cache, ArtworkChoice[] choices, CardEngine engine, Action ensureGameClosed)
    {
        ensureGameClosed();
        using var editLock = Lock(cache);
        var state = ReadState(cache);
        if (state.Pending is not null) state = Rollback(cache, state, ensureGameClosed);
        var indexFile = GameResources.AssetPath(cache, GameResources.Index);
        var indexHash = HashFile(indexFile);
        var index = GameResources.ReadIndex(cache).Items.ToDictionary(entry => entry.Name);
        var gate = state.OverFrame?.Gate;
        var registered = new Dictionary<string, int>(state.OverFrame?.Cards ?? []);
        var paths = new HashSet<string>();
        var changes = new List<Change>();
        var updateGate = false;

        foreach (var (card, variant) in choices)
        {
            if (card.Path is not string path || !paths.Add(path) || !index.TryGetValue(path, out var entry))
                throw new IOException($"「{card.Name}」在该账号的游戏资源中不可用。");
            updateGate |= registered.Remove(path);
            if (variant?.OverFrame is { Gate: string selectedGate } && card.Cid is int id)
            {
                if (gate is not null && gate != selectedGate)
                    throw new IOException("超框登记路径已变化。请先恢复以前应用的超框异画。");
                gate = selectedGate;
                registered.Add(path, id);
                updateGate = true;
            }
            try { Stage(entry, variant?.Id, original => variant is null ? original : engine.MakePatch(card, variant, original)); }
            catch (Exception error) when (error is IOException or InvalidDataException or TimeoutException)
            {
                throw new IOException($"「{card.Name}」{error.Message}", error);
            }
        }

        if (updateGate)
        {
            if (gate is null || paths.Contains(gate) || !index.TryGetValue(gate, out var entry))
                throw new IOException("该账号缺少超框登记资源，请先完成游戏资源下载。");
            // A game update may already have restored cards outside this edit.
            foreach (var path in registered.Keys.Where(path => !paths.Contains(path)).ToArray())
            {
                if (!index.TryGetValue(path, out var existing)) { registered.Remove(path); continue; }
                var asset = GameResources.AssetPath(cache, path);
                if (!File.Exists(asset) || GameResources.Matches(asset, existing)) registered.Remove(path);
                else _ = ReadOriginal(cache, existing);
            }
            var oldIds = state.OverFrame?.Cards.Values.ToHashSet() ?? [];
            var beforeGate = changes.Count;
            Stage(entry, registered.Count == 0 ? null : 0,
                original => registered.Count == 0 ? original : engine.RewriteOverFrameGate(original, registered.Values));
            // Disable removed registrations before restoring their textures. Enable new ones after the textures are written.
            if (changes.Count > beforeGate && registered.Values.All(oldIds.Contains))
            {
                var change = changes[^1];
                changes.RemoveAt(changes.Count - 1);
                changes.Insert(0, change);
            }
        }

        var updated = new EditState(registered.Count == 0 ? null : new Registration(gate!, registered));
        ensureGameClosed();
        if (HashFile(indexFile) != indexHash) throw new IOException("游戏资源索引刚刚更新，请重新打开卡片搜索。");
        if (changes.Count == 0)
        {
            if (updateGate) WriteState(cache, updated);
            return;
        }
        state = state with { Pending = changes.ToArray() };
        WriteState(cache, state);
        try
        {
            foreach (var change in changes) WriteChange(cache, change, rollback: false, ensureGameClosed);
            WriteState(cache, updated);
        }
        catch
        {
            Rollback(cache, state, ensureGameClosed);
            throw;
        }
        ClearStage(cache, changes);

        void Stage(GameResources.Entry entry, int? id, Func<byte[], byte[]> replace)
        {
            ensureGameClosed();
            var asset = GameResources.AssetPath(cache, entry.Name);
            if (!File.Exists(asset)) throw new IOException("原版资源尚未下载。请先进入游戏查看该卡。");
            var before = File.ReadAllBytes(asset);
            var original = IsOriginal(before, entry) ? before : ReadOriginal(cache, entry);
            var beforeHash = Hash(before);
            var history = ReadHistory(cache, entry) ?? new([]);
            if (!beforeHash.Equals(entry.Hash, StringComparison.OrdinalIgnoreCase) && !history.Variants.ContainsKey(beforeHash))
                throw new IOException("资源已被游戏或其他程序修改，请重新核对资源。");
            var after = replace(original);
            var afterHash = Hash(after);
            if (beforeHash == afterHash) return;

            if (id is int variant && !afterHash.Equals(entry.Hash, StringComparison.OrdinalIgnoreCase))
            {
                var backup = StatePath(cache, entry, ".original");
                if (!File.Exists(backup) || !GameResources.Matches(backup, entry))
                    SteamSession.AtomicWrite(backup, original);
                history.Variants[afterHash] = variant;
                SteamSession.AtomicWrite(StatePath(cache, entry, ".json"), JsonSerializer.Serialize(history));
            }
            var change = new Change(entry.Name, changes.Count, beforeHash, afterHash);
            SteamSession.AtomicWrite(Staged(cache, change, before: true), before);
            SteamSession.AtomicWrite(Staged(cache, change, before: false), after);
            changes.Add(change);
        }
    }

    public static void RecoverPending(string cache, Action ensureGameClosed)
    {
        if (ReadState(cache).Pending is null) return;
        if (!Directory.Exists(cache) || (File.GetAttributes(cache) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("异画所在的原缓存不可用。请先恢复原缓存。");
        using var editLock = Lock(cache);
        var state = ReadState(cache);
        if (state.Pending is not null) Rollback(cache, state, ensureGameClosed);
    }

    private static EditState Rollback(string cache, EditState state, Action ensureGameClosed)
    {
        try
        {
            var changes = state.Pending ?? throw new InvalidOperationException("找不到待恢复的异画记录。");
            Exception? failure = null;
            foreach (var change in changes.Reverse())
            {
                try { WriteChange(cache, change, rollback: true, ensureGameClosed); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failure ??= error; }
            }
            if (failure is not null) throw failure;
            var restored = state with { Pending = null };
            WriteState(cache, restored);
            ClearStage(cache, changes);
            return restored;
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            throw new IOException($"上次异画写入尚未恢复。{error.Message}", error);
        }
    }

    private static void WriteChange(string cache, Change change, bool rollback, Action ensureGameClosed)
    {
        ensureGameClosed();
        var asset = GameResources.AssetPath(cache, change.Asset);
        var hash = HashFile(asset);
        var expected = rollback ? change.After : change.Before;
        var desired = rollback ? change.Before : change.After;
        if (hash == desired) return;
        if (hash != expected) throw new IOException("游戏资源已被其他程序修改。");
        var bytes = File.ReadAllBytes(Staged(cache, change, before: rollback));
        if (Hash(bytes) != desired) throw new IOException("异画暂存文件未通过校验。");
        ensureGameClosed();
        SteamSession.AtomicWrite(asset, bytes);
    }

    private static void ClearStage(string cache, IEnumerable<Change> changes)
    {
        foreach (var change in changes)
        {
            try
            {
                File.Delete(Staged(cache, change, before: true));
                File.Delete(Staged(cache, change, before: false));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static string Staged(string cache, Change change, bool before) =>
        StateFile(cache, $"stage-{change.Slot}-{(before ? "before" : "after")}.bin");

    private static EditState ReadState(string cache)
    {
        var file = StateFile(cache, "state.json");
        return File.Exists(file) ? JsonSerializer.Deserialize<EditState>(File.ReadAllText(file))
            ?? throw new InvalidDataException("异画记录格式异常。") : new();
    }

    private static void WriteState(string cache, EditState state) =>
        SteamSession.AtomicWrite(StateFile(cache, "state.json"), JsonSerializer.Serialize(state));

    private static FileStream Lock(string cache)
    {
        var file = StateFile(cache, "edit.lock");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        return new FileStream(file, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
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

    private static string StateFile(string cache, string name)
    {
        var root = Path.Combine(Path.GetDirectoryName(cache)!, ".md-switcher-artwork");
        var file = Path.Combine(root, name);
        foreach (var path in new[] { root, file })
            if (Path.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("异画备份路径包含链接，已停止操作。");
        return file;
    }
}

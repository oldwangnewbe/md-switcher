using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace MDSwitcher;

internal sealed class RoyalFinishSettings(string directory)
{
    private const int CardLimit = 65536;
    private string FilePath => Path.Combine(directory, "royal-finish.json");
    public IReadOnlyDictionary<ulong, int[]> Accounts { get; private set; } = new Dictionary<ulong, int[]>();

    public static bool Supports(int id) => id is > 0 and < CardLimit;

    public void Load()
    {
        var saved = File.Exists(FilePath)
            ? JsonSerializer.Deserialize<Dictionary<ulong, int[]>>(File.ReadAllText(FilePath))
                ?? throw new InvalidDataException("动态镜碎设置格式异常。")
            : [];
        Accounts = saved.Where(pair => pair.Value is not null).Select(pair =>
            (pair.Key, Cards: pair.Value.Where(Supports).Distinct().Order().ToArray()))
            .Where(pair => pair.Cards.Length > 0).ToDictionary(pair => pair.Key, pair => pair.Cards);
    }

    public void Update(IEnumerable<ulong> accounts, IEnumerable<int> cardIds, bool enable)
    {
        var ids = cardIds.Where(Supports).ToArray();
        var updated = new Dictionary<ulong, int[]>(Accounts);
        foreach (var account in accounts)
        {
            var cards = new HashSet<int>(updated.GetValueOrDefault(account) ?? []);
            if (enable) cards.UnionWith(ids);
            else cards.ExceptWith(ids);
            if (cards.Count > 0) updated[account] = cards.Order().ToArray();
            else updated.Remove(account);
        }
        SteamSession.AtomicWrite(FilePath, JsonSerializer.Serialize(updated));
        Accounts = updated;
    }

    public static byte[] SelectionFile(int[] ids)
    {
        if (ids.Length == 0 || ids.Any(id => !Supports(id)))
            throw new InvalidDataException("动态镜碎选项包含无效的卡片编号。");
        var bytes = new byte[CardLimit / 8];
        foreach (var id in ids) bytes[id / 8] |= (byte)(1 << (id % 8));
        return bytes;
    }
}

internal static class RoyalFinishLoader
{
    public static int Load(Installation install, string directory, int pid, int[] cards)
    {
        var components = Path.Combine(AppContext.BaseDirectory, "RoyalFinish");
        var loader = Path.Combine(components, "MDRoyalLoader.exe");
        var renderer = Path.Combine(components, "MDRoyalFinish.dll");
        if (!File.Exists(loader) || !File.Exists(renderer))
            throw new IOException("找不到动态镜碎组件。请解压整个 ZIP，并保留程序旁边的 RoyalFinish 文件夹。");
        var selection = Path.Combine(directory, $"royal-finish-{Guid.NewGuid():N}.bin");
        SteamSession.AtomicWrite(selection, RoyalFinishSettings.SelectionFile(cards));
        try
        {
            var start = new ProcessStartInfo(loader)
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, WorkingDirectory = components,
            };
            string[] arguments = [Path.Combine(install.Game, "masterduel.exe"), renderer, selection,
                Path.Combine(directory, "royal-finish.log"), pid.ToString(CultureInfo.InvariantCulture)];
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new IOException("无法启动动态镜碎组件。");
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(45_000))
            {
                if (!process.HasExited) process.Kill();
                throw new TimeoutException("等待动态镜碎组件超时。");
            }
            const string prefix = "MD_ROYAL_RESULT=";
            var line = output.GetAwaiter().GetResult().Split('\n').LastOrDefault(line => line.StartsWith(prefix, StringComparison.Ordinal));
            if (process.ExitCode != 0 || line is null || !int.TryParse(line.AsSpan(prefix.Length), out var result))
                throw new IOException("动态镜碎组件未返回加载结果。");
            return result;
        }
        finally { File.Delete(selection); }
    }
}

using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace MDSwitcher;

internal sealed record SteamGameLaunch(int Pid, DateTime LocalTime)
{
    public static SteamGameLaunch? Current(string log)
    {
        SteamGameLaunch? launch = null;
        const string added = "AppID " + Installation.AppId + " adding PID ";
        const string stopped = "AppID " + Installation.AppId + " no longer tracking PID ";
        foreach (var line in log.Split('\n'))
        {
            if (line.Length < 22 || line[0] != '[' || line[20] != ']') continue;
            var entry = line.AsSpan(21).Trim();
            if (entry.StartsWith(added, StringComparison.Ordinal) &&
                ReferencesGame(entry) &&
                ReadPid(entry[added.Length..]) is int pid &&
                DateTime.TryParseExact(line.AsSpan(1, 19), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var time))
                launch = new SteamGameLaunch(pid, time);
            else if (entry.SequenceEqual("Remove " + Installation.AppId + " from running list") ||
                launch is not null && entry.StartsWith(stopped, StringComparison.Ordinal) && ReadPid(entry[stopped.Length..]) == launch.Pid)
                launch = null;
        }
        return launch;
    }

    private static bool ReferencesGame(ReadOnlySpan<char> text)
    {
        const string executable = "\\masterduel.exe";
        var index = text.IndexOf(executable, StringComparison.OrdinalIgnoreCase);
        if (index < 0) return false;
        var end = index + executable.Length;
        return end == text.Length || text[end] == '"' || char.IsWhiteSpace(text[end]);
    }

    private static int? ReadPid(ReadOnlySpan<char> text)
    {
        var count = 0;
        while (count < text.Length && char.IsAsciiDigit(text[count])) count++;
        return count > 0 && count < text.Length && (text[count] is ' ' or ',') &&
            int.TryParse(text[..count], out var pid) && pid > 0 ? pid : null;
    }
}

internal sealed class SteamRoyalFinishMonitor(Installation install, string stateDirectory)
{
    private (long Length, DateTime Written)? version;
    private SteamGameLaunch? current;
    private SteamGameLaunch? handled;

    public string? Poll(IReadOnlyDictionary<ulong, int[]> selections)
    {
        var session = new SteamSession(install, stateDirectory);
        if (session.CanRecover) return null;
        var launch = ReadLaunch();
        if (launch is null || launch == handled || !TryVerifyProcess(launch, out var started)) return null;
        if (selections.Count == 0) { handled = launch; return null; }
        var account = session.ActiveAccount();
        if (account is null) return null;
        if (!selections.TryGetValue(account.Value, out var cards) || cards.Length == 0)
        {
            handled = launch;
            return null;
        }
        if (session.CanRecover || !TryVerifyProcess(launch, out var confirmedStart) || started != confirmedStart ||
            session.ActiveAccount() != account) return null;
        handled = launch;
        var result = RoyalFinishLoader.Load(install, stateDirectory, launch.Pid, cards);
        if (result == 0) return "动态镜碎已加载。";
        var detail = result switch
        {
            11 => "本次启动的游戏进程已退出或改变。",
            12 or 13 => "无法访问游戏进程或加载渲染 DLL。请确认程序和 Steam 的运行权限一致。",
            102 or 104 or 105 => "当前游戏版本的卡面渲染接口不匹配。",
            14 or 103 => "等待游戏渲染组件超时。",
            _ => "渲染组件未能启用。",
        };
        return $"动态镜碎未加载。{detail}（{result}）";
    }

    private SteamGameLaunch? ReadLaunch()
    {
        var file = new FileInfo(Path.Combine(install.Steam, "logs", "gameprocess_log.txt"));
        if (!file.Exists) { version = null; return current = null; }
        var updated = (file.Length, file.LastWriteTimeUtc);
        if (version == updated) return current;
        using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var length = stream.Length;
        var buffer = new byte[(int)Math.Min(length, 65_536)];
        stream.Position = length - buffer.Length;
        var count = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
        var end = buffer.AsSpan(0, count).LastIndexOf((byte)'\n');
        version = updated;
        current = end < 0 ? null : SteamGameLaunch.Current(Encoding.UTF8.GetString(buffer, 0, end + 1));
        return current;
    }

    private bool TryVerifyProcess(SteamGameLaunch launch, out DateTime started)
    {
        started = default;
        try
        {
            using var process = Process.GetProcessById(launch.Pid);
            if (process.HasExited || !process.ProcessName.Equals("masterduel", StringComparison.OrdinalIgnoreCase) ||
                process.MainModule?.FileName is not string file || !Installation.SamePath(file, Path.Combine(install.Game, "masterduel.exe")))
                return false;
            started = process.StartTime;
            // The log records when Steam began tracking the process, to the nearest second.
            var delay = launch.LocalTime - started;
            return delay >= TimeSpan.FromSeconds(-2) && delay <= TimeSpan.FromSeconds(30);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return false;
        }
    }
}

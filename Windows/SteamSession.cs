using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace MDSwitcher;

internal sealed record Account(ulong Id, string Name, string Persona, bool Remembered, bool Preferred)
{
    public override string ToString() => $"{(Persona.Length == 0 ? Name : Persona)}  ({Name})"
        + (Remembered ? "" : " · 需要先登录");
}

internal sealed partial class SteamSession(Installation install, string state)
{
    private const ulong SteamIdBase = 76561197960265728;
    private const string SteamKey = @"Software\Valve\Steam";
    private const string LoginValue = "AutoLoginUser";
    private string JournalPath => Path.Combine(state, "pending-login.json");

    private sealed record Journal(string File, string Original, string Updated, string? Previous, string Next);
    public bool CanRecover => File.Exists(JournalPath);

    public static Account[] ReadAccounts(Installation install)
    {
        if (!File.Exists(install.LoginFile)) return [];
        return Accounts(ReadLoginFile(install.LoginFile)).Select(pair => pair.Account).ToArray();
    }

    private static (Account Account, VdfField Entry)[] Accounts(string text)
    {
        var users = Vdf.Parse(text).Field("users")?.Fields ??
            throw new InvalidDataException("找不到 Steam 账号列表。");
        List<(Account, VdfField)> accounts = [];
        HashSet<ulong> ids = [];
        HashSet<string> names = new(StringComparer.OrdinalIgnoreCase);
        foreach (var user in users)
        {
            var fields = user.Fields ?? throw new InvalidDataException("Steam 账号格式异常。");
            var name = fields.Field("AccountName")?.Value;
            if (!ulong.TryParse(user.Name, out var id) || id <= SteamIdBase || id - SteamIdBase > uint.MaxValue
                || name is null || !NamePattern().IsMatch(name) || !names.Add(name) || !ids.Add(id))
                throw new InvalidDataException("Steam 账号列表有无法识别或重复的账号。");
            var remembered = fields.Field("RememberPassword")?.Value == "1";
            var preferred = (fields.Field("AutoLogin") ?? fields.Field("MostRecent"))?.Value == "1";
            accounts.Add((new(id, name, fields.Field("PersonaName")?.Value ?? "", remembered, preferred), user));
        }
        return accounts.ToArray();
    }

    public async Task RunAsync(Account account, bool launch, IProgress<string> progress, ResourceSettings? resources)
    {
        if (CanRecover) throw new InvalidOperationException("请先恢复未完成的 Steam 登录设置。");
        var active = ActiveAccount();
        if (active == account.Id && GameRunning())
        {
            progress.Report("所选账号的 Master Duel 已经在运行。");
            return;
        }

        RequireGameClosed();
        if (active != account.Id)
        {
            if (SteamRunning())
            {
                if (!ExpectedSteamRunning())
                    throw new InvalidOperationException("当前运行的 Steam 来自另一个目录，请先退出再试。");
                progress.Report("正在正常退出 Steam…");
                Start("-shutdown");
                await WaitAsync(() => !SteamRunning(), TimeSpan.FromSeconds(35),
                    "Steam 尚未退出，请在 Steam 菜单中退出后重试。");
            }
            RequireIdle();
            var original = ReadLoginFile(install.LoginFile);
            var updated = SelectAccount(original, account);
            var journal = new Journal(install.LoginFile, original, updated, GetLoginUser(), account.Name);
            AtomicWrite(JournalPath, JsonSerializer.Serialize(journal));
            try
            {
                RequireIdle();
                if (ReadLoginFile(install.LoginFile) != original)
                    throw new InvalidOperationException("Steam 配置刚刚被修改，请刷新后重试。");
                AtomicWrite(install.LoginFile, updated);
                SetLoginUser(account.Name);
                if (ReadLoginFile(install.LoginFile) != updated || GetLoginUser() != account.Name)
                    throw new InvalidOperationException("Steam 登录设置核对失败。");
                RequireIdle();
                Start("-login", account.Name);
            }
            catch
            {
                if (!SteamRunning() && !GameRunning()) Recover();
                throw;
            }
            File.Delete(JournalPath);
            progress.Report("等待 Steam 登录所选账号。如需 Steam Guard，请在 Steam 内完成。");
            await WaitAsync(() => ActiveAccount() == account.Id, TimeSpan.FromSeconds(120),
                "Steam 尚未登录所选账号，请在 Steam 中确认后重试。");
        }

        if (!launch)
        {
            progress.Report("已确认 Steam 登录所选账号。");
            return;
        }

        RequireGameClosed();
        if (resources is not null)
        {
            var folder = resources.MainAccount == account.Id ? resources.MainFolder : resources.Accounts.GetValueOrDefault(account.Id);
            if (folder is not null)
            {
                var cache = GameResources.CacheLocation(install, folder);
                var main = GameResources.CacheLocation(install, resources.MainFolder);
                if (account.Id == resources.MainAccount || SharedCache.IsLinkedTo(cache, main)) cache = main;
                ArtworkFiles.RecoverPending(cache, RequireGameClosed);
            }
        }
        if (resources is not null && resources.MainAccount != account.Id && resources.Accounts.ContainsKey(account.Id))
        {
            progress.Report("正在检查主账号资源和磁盘共享支持…");
            var added = await Task.Run(() => GameResources.Prepare(install, resources, account.Id,
                () => ActiveAccount() == account.Id, progress));
            if (added > 0) progress.Report($"已为小号准备 {added} 个资源文件，正在启动游戏…");
        }
        if (Installation.Find(install.Steam, install.Game, strict: true) is null)
            throw new InvalidOperationException("Master Duel 的 Steam 安装位置已变化，请刷新安装目录。");
        if (ActiveAccount() != account.Id)
            throw new InvalidOperationException("Steam 登录账号已变化，请确认后重试。");
        Start("-applaunch", Installation.AppId);
        progress.Report("已通过 Steam 请求启动 Master Duel。");
    }

    public void Recover()
    {
        RequireIdle();
        var journal = JsonSerializer.Deserialize<Journal>(File.ReadAllText(JournalPath))
            ?? throw new InvalidDataException("恢复记录格式异常。");
        if (!Installation.SamePath(journal.File, install.LoginFile))
            throw new InvalidOperationException("恢复记录属于另一套 Steam，请在安装目录中选择原来的安装。");
        var current = ReadLoginFile(install.LoginFile);
        var login = GetLoginUser();
        if ((current != journal.Original && current != journal.Updated)
            || (login != journal.Previous && login != journal.Next))
            throw new InvalidOperationException("Steam 登录设置已被其他程序修改，已保留恢复记录。");
        if (current != journal.Original) AtomicWrite(install.LoginFile, journal.Original);
        if (login != journal.Previous) SetLoginUser(journal.Previous);
        File.Delete(JournalPath);
    }

    private static string SelectAccount(string source, Account desired)
    {
        var accounts = Accounts(source);
        if (!accounts.Any(pair => pair.Account.Id == desired.Id && pair.Account.Name == desired.Name && pair.Account.Remembered))
            throw new InvalidOperationException("请先在 Steam 中登录此账号并选择记住登录。");
        var flags = new[] { "AutoLogin", "MostRecent" }
            .Where(flag => accounts.Any(pair => pair.Entry.Fields.Field(flag) is not null)).ToArray();
        if (flags.Length == 0) throw new InvalidDataException("无法识别 Steam 的自动登录设置。");
        List<(int Offset, int Length, string Value)> edits = [];
        foreach (var (account, record) in accounts)
        {
            var value = account.Id == desired.Id ? "1" : "0";
            var additions = new StringBuilder();
            foreach (var flag in flags)
            {
                var matching = record.Fields!.Where(field => field.Name.Equals(flag, StringComparison.OrdinalIgnoreCase)).ToArray();
                if (matching.Length > 1) throw new InvalidDataException("Steam 登录设置含有重复的字段。");
                if (matching.Length == 0) additions.Append($"\t\"{flag}\"\t\"{value}\"\r\n\t");
                else
                {
                    var field = matching[0];
                    if (field.Value is not ("0" or "1")) throw new InvalidDataException("Steam 登录标记格式异常。");
                    if (field.Value != value) edits.Add((field.Offset, field.Length, $"\"{value}\""));
                }
            }
            if (additions.Length > 0) edits.Add((record.Offset, 0, additions.ToString()));
        }
        var updated = new StringBuilder(source);
        foreach (var edit in edits.OrderByDescending(edit => edit.Offset))
            updated.Remove(edit.Offset, edit.Length).Insert(edit.Offset, edit.Value);
        return updated.ToString();
    }

    internal ulong? ActiveAccount()
    {
        using var key = Registry.CurrentUser.OpenSubKey(SteamKey + @"\ActiveProcess");
        if (key?.GetValue("pid") is not int pid || pid <= 0 ||
            key.GetValue("ActiveUser") is not int user || user == 0) return null;
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.ProcessName.Equals("steam", StringComparison.OrdinalIgnoreCase) &&
                process.MainModule?.FileName is string file && Installation.SamePath(file, install.SteamExe)
                ? SteamIdBase + unchecked((uint)user) : null;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return null;
        }
    }

    private bool ExpectedSteamRunning()
    {
        var processes = Process.GetProcessesByName("steam");
        try
        {
            return processes.Length == 1 && processes[0].MainModule?.FileName is string file
                && Installation.SamePath(file, install.SteamExe);
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
    }

    internal static bool GameRunning() => Running("masterduel");
    private static bool SteamRunning() => Running("steam");

    private static bool Running(string name)
    {
        var matches = Process.GetProcessesByName(name);
        foreach (var process in matches) process.Dispose();
        return matches.Length > 0;
    }

    private static void RequireGameClosed()
    {
        if (GameRunning()) throw new InvalidOperationException("请先退出正在运行的 Master Duel。");
    }

    private static void RequireIdle()
    {
        RequireGameClosed();
        if (SteamRunning()) throw new InvalidOperationException("请先正常退出 Steam。");
    }

    private void Start(params string[] arguments)
    {
        var start = new ProcessStartInfo(install.SteamExe) { WorkingDirectory = install.Steam, UseShellExecute = false };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动 Steam。");
    }

    private static string? GetLoginUser()
    {
        using var key = Registry.CurrentUser.OpenSubKey(SteamKey);
        return key?.GetValue(LoginValue) as string;
    }

    private static void SetLoginUser(string? name)
    {
        using var key = Registry.CurrentUser.CreateSubKey(SteamKey);
        if (name is null) key.DeleteValue(LoginValue, throwOnMissingValue: false);
        else key.SetValue(LoginValue, name, RegistryValueKind.String);
    }

    private static string ReadLoginFile(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Steam 登录配置是链接，请检查安装目录。");
        return new UTF8Encoding(false, true).GetString(File.ReadAllBytes(path));
    }

    internal static void AtomicWrite(string file, string text) =>
        AtomicWrite(file, new UTF8Encoding(false, true).GetBytes(text));

    internal static void AtomicWrite(string file, byte[] data)
    {
        var directory = Path.GetDirectoryName(file)!;
        Directory.CreateDirectory(directory);
        var temp = Path.Combine(directory, $".md-switcher-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temp, data);
            File.Move(temp, file, overwrite: true);
        }
        finally { File.Delete(temp); }
    }

    private static async Task WaitAsync(Func<bool> condition, TimeSpan timeout, string message)
    {
        var timer = Stopwatch.StartNew();
        while (!condition())
        {
            if (timer.Elapsed >= timeout) throw new TimeoutException(message);
            await Task.Delay(500);
        }
    }

    [GeneratedRegex(@"\A[A-Za-z0-9_]{1,64}\z")]
    private static partial Regex NamePattern();
}

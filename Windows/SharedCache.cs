using System.Diagnostics;

namespace MDSwitcher;

internal static class SharedCache
{
    private static string Backup(string cache) => Path.Combine(Path.GetDirectoryName(cache)!, ".md-switcher-independent-0000");

    public static bool HasBackup(Installation install, string folder)
    {
        try { return Directory.Exists(Backup(GameResources.CacheLocation(install, folder))); }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    public static bool IsLinkedTo(string cache, string source) => Directory.Exists(Backup(cache)) && PointsTo(cache, source);

    public static void Enable(Installation install, ResourceSettings settings, ulong account)
    {
        var (source, target) = Locations(install, settings, account);
        var backup = Backup(target);
        EnsureGameClosed();
        if (Directory.Exists(backup))
            throw new IOException("小号已有缓存备份，请先恢复原缓存。");
        _ = GameResources.Cache(install, settings.MainFolder);
        _ = GameResources.Cache(install, settings.Accounts[account]);
        ArtworkFiles.RecoverPending(source, EnsureGameClosed);
        ArtworkFiles.RecoverPending(target, EnsureGameClosed);
        if (!ResourceVolume.Read(source).CanHardLinkTo(ResourceVolume.Read(target)))
            throw new IOException("快速共享需要大号和小号的缓存位于同一个 NTFS 卷。");

        var original = GameResources.ReadIndex(source).Items.ToDictionary(item => item.Name, StringComparer.OrdinalIgnoreCase);
        if (original.Count == 0 || GameResources.ReadIndex(target).Items.Any(item =>
            !original.TryGetValue(item.Name, out var shared) || shared != item))
            throw new IOException("大号和小号的资源版本不匹配，请先核对游戏更新和语言。");

        var pendingLink = TemporaryLink(target);
        try
        {
            CreateJunction(pendingLink, source);
            if (!PointsTo(pendingLink, source)) throw new IOException("快速共享未指向大号缓存。");
            EnsureGameClosed();
            Directory.Move(target, backup);
            try { Directory.Move(pendingLink, target); }
            catch
            {
                if (!Path.Exists(target)) Directory.Move(backup, target);
                throw;
            }
        }
        finally { if (Path.Exists(pendingLink)) Directory.Delete(pendingLink, recursive: false); }
    }

    public static void Restore(Installation install, ResourceSettings settings, ulong account)
    {
        var (source, target) = Locations(install, settings, account);
        var backup = Backup(target);
        EnsureGameClosed();
        if (!Directory.Exists(backup) || (File.GetAttributes(backup) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("找不到小号原缓存备份。");
        if (!Path.Exists(target))
        {
            Directory.Move(backup, target);
            return;
        }
        if (!PointsTo(target, source)) throw new IOException("小号缓存已发生变化，请保留当前目录并检查备份。");

        var pendingLink = TemporaryLink(target);
        Directory.Move(target, pendingLink);
        try { Directory.Move(backup, target); }
        catch
        {
            if (!Path.Exists(target)) Directory.Move(pendingLink, target);
            throw;
        }
        Directory.Delete(pendingLink, recursive: false);
    }

    private static bool PointsTo(string cache, string source) => Path.Exists(cache)
        && Directory.ResolveLinkTarget(cache, returnFinalTarget: false) is DirectoryInfo destination
        && Installation.SamePath(destination.FullName, source);

    private static (string Source, string Target) Locations(Installation install, ResourceSettings settings, ulong account)
    {
        if (account == settings.MainAccount || !settings.Accounts.TryGetValue(account, out var folder) ||
            settings.MainFolder.Equals(folder, StringComparison.OrdinalIgnoreCase) ||
            settings.Accounts.Count(pair => pair.Value.Equals(folder, StringComparison.OrdinalIgnoreCase)) != 1)
            throw new IOException("请先给所选小号绑定独立的资源目录。");
        return (GameResources.CacheLocation(install, settings.MainFolder), GameResources.CacheLocation(install, folder));
    }

    private static void EnsureGameClosed()
    {
        if (SteamSession.GameRunning()) throw new IOException("请先退出 Master Duel，再更改缓存共享方式。");
    }

    private static string TemporaryLink(string target) =>
        Path.Combine(Path.GetDirectoryName(target)!, $".md-switcher-link-{Guid.NewGuid():N}");

    private static void CreateJunction(string link, string target)
    {
        // Pass paths through quoted variables and disable delayed expansion for names containing ! or %.
        var command = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"))
        {
            Arguments = "/d /v:off /c mklink /j \"%MD_SWITCHER_JUNCTION%\" \"%MD_SWITCHER_SOURCE%\"",
            UseShellExecute = false, CreateNoWindow = true,
        };
        command.Environment["MD_SWITCHER_JUNCTION"] = link;
        command.Environment["MD_SWITCHER_SOURCE"] = target;
        using var process = Process.Start(command) ?? throw new IOException("无法启动 Windows 目录链接命令。");
        if (!process.WaitForExit(5_000))
        {
            process.Kill();
            process.WaitForExit();
            throw new IOException("建立目录链接超时。");
        }
        if (process.ExitCode != 0) throw new IOException("无法建立目录链接，请检查游戏目录的写入权限。");
    }
}

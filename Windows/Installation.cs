using Microsoft.Win32;

namespace MDSwitcher;

internal sealed record Installation(string Steam, string Game)
{
    public const string AppId = "1449850";
    public string SteamExe => Path.Combine(Steam, "steam.exe");
    public string LoginFile => Path.Combine(Steam, "config", "loginusers.vdf");

    public static Installation? Find(string? preferredSteam, string? preferredGame, bool strict = false)
    {
        IEnumerable<string> roots = strict && preferredSteam is not null ? [preferredSteam] : SteamRoots(preferredSteam);
        foreach (var steam in roots.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(Path.Combine(steam, "steam.exe"))) continue;
            var games = Libraries(steam).Select(GameInLibrary).OfType<string>()
                .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (games.Length != 1) continue;
            if (preferredGame is not null && SamePath(preferredGame, games[0]))
                return new(steam, games[0]);
            if (preferredGame is null) return new(steam, games[0]);
        }
        return strict || preferredGame is null ? null : Find(preferredSteam, null);
    }

    public static string? FindMDPro3(string? preferred, Installation? install)
    {
        if (preferred is not null && IsMDPro3(preferred)) return preferred;
        var common = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var x86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roots = new[] { common, x86, local, Path.Combine(local, "Programs"), install?.Steam,
                            install is null ? null : Path.GetDirectoryName(install.Game) };
        var candidates = roots.OfType<string>().Where(path => path.Length > 0)
            .Select(path => Path.Combine(path, "MDPro3"))
            .Concat(InstalledMDPro3()).Where(IsMDPro3)
            .Select(path => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return candidates.Length == 1 ? candidates[0] : null;
    }

    public static bool IsMDPro3(string folder) =>
        Directory.Exists(Path.Combine(folder, "Picture", "Art")) &&
        File.Exists(Path.Combine(folder, "Data", "locales", "zh-CN", "cards.cdb")) &&
        File.Exists(Path.Combine(folder, "Data", "cards_Lite.json"));

    public static bool SamePath(string left, string right) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)).Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)), StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<string> SteamRoots(string? preferred)
    {
        if (preferred is not null) yield return preferred;
        using var user = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
        if (user?.GetValue("SteamPath") is string userPath && Path.IsPathFullyQualified(userPath))
            yield return userPath;
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32);
        using var key = machine.OpenSubKey(@"SOFTWARE\Valve\Steam");
        if (key?.GetValue("InstallPath") is string machinePath && Path.IsPathFullyQualified(machinePath))
            yield return machinePath;
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Steam");
    }

    private static IEnumerable<string> Libraries(string steam)
    {
        yield return steam;
        var listing = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
        if (!File.Exists(listing)) yield break;
        var libraries = Vdf.Parse(File.ReadAllText(listing)).Field("libraryfolders")?.Fields ?? [];
        foreach (var library in libraries)
        {
            if (!int.TryParse(library.Name, out _)) continue;
            var path = library.Fields.Field("path")?.Value ?? library.Value;
            if (path is not null && Path.IsPathFullyQualified(path)) yield return path;
        }
    }

    private static string? GameInLibrary(string library)
    {
        var apps = Path.Combine(library, "steamapps");
        var manifest = Path.Combine(apps, $"appmanifest_{AppId}.acf");
        if (!File.Exists(manifest)) return null;
        var state = Vdf.Parse(File.ReadAllText(manifest)).Field("AppState")?.Fields;
        var name = state.Field("installdir")?.Value;
        if (state.Field("appid")?.Value != AppId || string.IsNullOrWhiteSpace(name) ||
            name is "." or ".." || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            return null;
        var game = Path.Combine(apps, "common", name);
        return File.Exists(Path.Combine(game, "masterduel.exe")) ? game : null;
    }

    private static IEnumerable<string> InstalledMDPro3()
    {
        foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            using var root = RegistryKey.OpenBaseKey(hive, view);
            using var apps = root.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall");
            if (apps is null) continue;
            foreach (var name in apps.GetSubKeyNames())
            {
                using var app = apps.OpenSubKey(name);
                if (app?.GetValue("DisplayName") is string title && title.Contains("MDPro3", StringComparison.OrdinalIgnoreCase)
                    && app.GetValue("InstallLocation") is string folder && Path.IsPathFullyQualified(folder))
                    yield return folder;
            }
        }
    }
}

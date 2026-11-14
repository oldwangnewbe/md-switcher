using System.Text.Json;

namespace MDSwitcher;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\MDSwitcher.Windows", out var first);
        if (!first) return;
        ApplicationConfiguration.Initialize();
        Application.Run(new MainWindow());
    }
}

internal sealed record Settings(string? Steam = null, string? Game = null, string? MDPro3 = null, Dictionary<string, ResourceSettings>? Resources = null,
    Dictionary<ulong, string>? Aliases = null);

internal sealed partial class MainWindow : Form
{
    private static readonly string StateDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MD Switcher");
    private static readonly string SettingsFile = Path.Combine(StateDirectory, "installation.json");
    private Settings settings = new();
    private Installation? install;
    private string? proDirectory;
    private readonly Label subtitle = Ui.Label("Steam · Master Duel", true);
    private readonly Label status = Ui.Field("", 20);
    private readonly ChoiceList<Account> accounts;
    private readonly Button launch = Ui.Button("启动 MD", primary: true);
    private readonly Button switchSteam = Ui.Button("仅切换 Steam");
    private readonly Button recover = Ui.Button("恢复登录设置");
    private readonly Button refresh = Ui.Button("刷新账号");
    private readonly Button preferences = Ui.Button("设置");
    private readonly Button artwork = Ui.Button("卡片搜索");
    private readonly Button artworkCollections = Ui.Button("异画合集");
    private readonly Button performances = Ui.Button("卡片演出");
    private readonly Button accountPage = Ui.Button("账号切换");
    private readonly Panel content = new() { Dock = DockStyle.Fill };
    private readonly TableLayoutPanel accountContent;
    private ArtworkPage? cardPage;
    private PerformancePage? performancePage;
    private Button? activePage;
    private bool busy;

    public MainWindow()
    {
        SuspendLayout();
        Text = "决斗匣";
        Ui.Style(this);
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        ClientSize = new Size(1040, 620);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        DpiChanged += (_, _) => BeginInvoke(FitWindowToScreen);

        accounts = new ChoiceList<Account>(69, DrawAccount, account =>
            $"{AccountLabel(account)}，Steam：{account.Name}，LocalData：{FolderFor(account.Id) ?? "未绑定"}")
        { AccessibleName = "Steam 账号列表" };
        accountContent = BuildAccounts();
        Controls.Add(BuildFrame());
        Navigate(accountPage, accountContent);
        ResumeLayout();

        Shown += (_, _) => Execute(() =>
        {
            royalTimer.Start();
            FitWindowToScreen();
            LoadSettings();
            LoadRoyalSettings();
            RefreshInstall();
        });
        royalTimer.Tick += async (_, _) => await PollRoyalFinishAsync();
        refresh.Click += (_, _) => Execute(() => RefreshInstall());
        preferences.Click += (_, _) => Execute(ShowSettings);
        artwork.Click += (_, _) => Execute(() => ShowArtwork(collections: false));
        artworkCollections.Click += (_, _) => Execute(() => ShowArtwork(collections: true));
        performances.Click += (_, _) => Execute(ShowPerformances);
        royalFinish.Click += (_, _) => Execute(ShowRoyalFinish);
        accountPage.Click += (_, _) => Execute(() => Navigate(accountPage, accountContent));
        Activated += (_, _) => UpdateButtons();
        resourcePrimary.Click += (_, _) => Execute(() => resourceAction?.Invoke());
        resourceMore.Click += (_, _) => Execute(ShowResourceOptions);
        rename.Click += (_, _) => Execute(RenameAccount);
        accounts.SelectedIndexChanged += (_, _) =>
        {
            if (!busy) status.Text = "";
            ClearCardPage();
            UpdateButtons();
        };
        launch.Click += async (_, _) => await RunAsync(launch: true);
        switchSteam.Click += async (_, _) => await RunAsync(launch: false);
        recover.Click += (_, _) => Execute(() =>
        {
            if (install is null) return;
            new SteamSession(install, StateDirectory).Recover();
            RefreshInstall("Steam 登录设置已恢复。");
        });
        FormClosing += (_, args) =>
        {
            if (busy || cardPage?.Busy == true || royalPage?.Busy == true || performancePage?.Busy == true) args.Cancel = true;
        };
        FormClosed += (_, _) => { royalTimer.Dispose(); ClearCardPage(); tips.Dispose(); };
        UpdateButtons();
    }

    private int Scale(int pixels) => Ui.Dip(pixels, DeviceDpi);

    private void FitWindowToScreen()
    {
        var work = Screen.FromControl(this).WorkingArea;
        var available = new Size(Math.Max(1, work.Width - Scale(20)), Math.Max(1, work.Height - Scale(16)));
        var fit = new Size(Math.Min(Width, available.Width), Math.Min(Height, available.Height));
        if (fit != Size)
            Bounds = new Rectangle(work.Left + (work.Width - fit.Width) / 2, work.Top + (work.Height - fit.Height) / 2,
                fit.Width, fit.Height);
    }

    private void LoadSettings()
    {
        if (File.Exists(SettingsFile))
            settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsFile)) ?? new();
    }

    private void RefreshInstall(string? message = null)
    {
        ClearCardPage();
        var selected = (accounts.SelectedItem as Account)?.Id;
        install = null;
        accounts.SetItems([]);
        install = Installation.Find(settings.Steam, settings.Game, strict: settings.Steam is not null && settings.Game is null
            && File.Exists(Path.Combine(settings.Steam, "steam.exe")));
        proDirectory = Installation.FindMDPro3(settings.MDPro3, install);
        subtitle.Text = install is null ? "尚未找到 Steam 版 Master Duel"
            : proDirectory is null ? "Master Duel 已连接 · 可在设置中选择 MDPro3"
            : "Master Duel 已连接   ·   MDPro3 已连接";
        if (install is not null)
        {
            var saved = SteamSession.ReadAccounts(install);
            accounts.SetItems(saved, saved.FirstOrDefault(account => account.Id == selected)
                ?? saved.FirstOrDefault(account => account.Preferred && account.Remembered)
                ?? saved.FirstOrDefault(account => account.Remembered) ?? saved.FirstOrDefault());
        }
        status.Text = message ?? (install is null ? "请在「设置」中选择 Steam 和 Master Duel 的安装目录。"
            : accounts.Items.Count == 0 ? "请先在 Steam 中登录账号并记住登录，再点「刷新」。"
            : "");
        UpdateButtons();
    }

    private void SaveAndRefresh(Settings updated)
    {
        SteamSession.AtomicWrite(SettingsFile, JsonSerializer.Serialize(updated));
        settings = updated;
        RefreshInstall();
    }

    private void ChooseSteam()
    {
        var folder = Pick("请选择包含 steam.exe 的文件夹", install?.Steam ?? settings.Steam);
        if (folder is null) return;
        if (!File.Exists(Path.Combine(folder, "steam.exe")))
            throw new InvalidDataException("这个目录找不到 steam.exe。");
        SaveAndRefresh(settings with { Steam = folder, Game = null });
    }

    private void ChooseGame()
    {
        var folder = Pick("请选择包含 masterduel.exe 的游戏文件夹", install?.Game);
        if (folder is null) return;
        var result = Installation.Find(settings.Steam, folder, strict: true);
        if (result is null)
            throw new InvalidDataException("该目录与 Steam 已登记的 Master Duel 安装不匹配。请先在 Steam 库中确认安装位置。");
        SaveAndRefresh(settings with { Steam = result.Steam, Game = result.Game });
    }

    private void ChoosePro()
    {
        var folder = Pick("请选择包含 Data 和 Picture 的 MDPro3 文件夹", proDirectory);
        if (folder is null) return;
        if (!Installation.IsMDPro3(folder))
            throw new InvalidDataException("这个目录缺少 MDPro3 的简中卡库、卡片映射或卡图。");
        SaveAndRefresh(settings with { MDPro3 = folder });
    }

    private string? Pick(string description, string? initial)
    {
        using var picker = new FolderBrowserDialog
        {
            Description = description, UseDescriptionForTitle = true, ShowNewFolderButton = false,
            SelectedPath = initial ?? "",
        };
        return picker.ShowDialog(Form.ActiveForm ?? this) == DialogResult.OK ? picker.SelectedPath : null;
    }

    private async Task RunAsync(bool launch)
    {
        if (busy || install is null || accounts.SelectedItem is not Account { Remembered: true } account) return;
        busy = true;
        UpdateButtons();
        status.Text = "正在核对 Steam 当前账号…";
        try
        {
            var progress = new Progress<string>(message => status.Text = message);
            await new SteamSession(install, StateDirectory).RunAsync(account, launch, progress, CurrentResources);
        }
        catch (Exception error) { status.Text = error.Message; }
        finally { busy = false; UpdateButtons(); }
    }

    private ResourceSettings? CurrentResources => install is null
        ? null : settings.Resources?.GetValueOrDefault(install.Game.ToUpperInvariant());

    private void BindResources(bool main)
    {
        if (install is null || accounts.SelectedItem is not Account account) return;
        if (SteamSession.GameRunning())
            throw new InvalidOperationException("请先退出游戏，再绑定资源目录。");
        var current = CurrentResources;
        if (!main && (current is null || account.Id == current.MainAccount))
            throw new InvalidOperationException("请先为另一个账号设置主账号资源。");
        var folder = PickResourceFolder(install, account, main);
        if (folder is null) return;
        var name = GameResources.Identify(install, folder);
        if (current is not null)
        {
            var movedSharedSource = main && !name.Equals(current.MainFolder, StringComparison.OrdinalIgnoreCase)
                && current.Accounts.Values.Any(value => SharedCache.HasBackup(install, value));
            var movedSharedTarget = !main && current.Accounts.TryGetValue(account.Id, out var previous)
                && !name.Equals(previous, StringComparison.OrdinalIgnoreCase) && SharedCache.HasBackup(install, previous);
            if (movedSharedSource || movedSharedTarget)
                throw new IOException("请先为使用快速共享的小号恢复原缓存，再更改资源绑定。");
        }
        var mappings = new Dictionary<ulong, string>(current?.Accounts ?? []);
        if (mappings.Any(pair => pair.Key != account.Id && pair.Value.Equals(name, StringComparison.OrdinalIgnoreCase))
            || current is not null && current.MainAccount != account.Id
                && name.Equals(current.MainFolder, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("这个目录已绑定给另一个账号。");
        if (main)
        {
            if (current is not null && current.MainAccount != account.Id)
                mappings[current.MainAccount] = current.MainFolder;
            mappings.Remove(account.Id);
        }
        else mappings[account.Id] = name;
        var resource = main ? new ResourceSettings(account.Id, name, mappings) : current! with { Accounts = mappings };
        var byGame = new Dictionary<string, ResourceSettings>(settings.Resources ?? []);
        byGame[install.Game.ToUpperInvariant()] = resource;
        SaveAndRefresh(settings with { Resources = byGame });
        status.Text = main ? "已设为资源主账号。选中其他账号即可绑定并共享。"
            : "已绑定游戏目录。可直接启用快速共享，或保持独立缓存。";
    }

    private void ChangeSharedCache(bool enable)
    {
        if (install is null || CurrentResources is not { } mappings || accounts.SelectedItem is not Account account) return;
        if (enable) SharedCache.Enable(install, mappings, account.Id);
        else SharedCache.Restore(install, mappings, account.Id);
        ClearCardPage();
        status.Text = enable ? "快速共享已开启。小号可直接启动，原缓存已保留。" : "已恢复小号原缓存。";
    }

    private void ShowArtwork(bool collections)
    {
        var pageButton = collections ? artworkCollections : artwork;
        if (cardPage is not null)
        {
            cardPage.ShowCollections(collections);
            Navigate(pageButton, cardPage);
            return;
        }
        if (install is null || proDirectory is null)
            throw new InvalidOperationException("请先在设置中确认 Master Duel 和 MDPro3 的目录。");
        var resource = CurrentResources ?? throw new InvalidOperationException(
            "请在「账号切换」选中已下载完整资源的账号，再点「设为资源主账号」。");
        var source = GameResources.Cache(install, resource.MainFolder);
        var bound = accounts.Items.Select(account =>
        {
            var folder = FolderFor(account.Id);
            var shared = folder is not null && SharedCache.HasBackup(install, folder);
            return (account.Id, Shared: shared, Target: folder is null || shared ? null : new ArtworkTarget(
                AccountLabel(account), folder));
        }).ToArray();
        var targets = bound.Select(entry => entry.Target).OfType<ArtworkTarget>().ToArray();
        if (targets.Select(target => target.Folder).Distinct(StringComparer.OrdinalIgnoreCase).Count() != targets.Length)
            throw new InvalidOperationException("有多个账号绑定了同一个目录，请先检查资源绑定。");
        var selected = (accounts.SelectedItem as Account)?.Id;
        var selectedResource = bound.FirstOrDefault(entry => entry.Id == selected);
        var page = new ArtworkPage(install, new CardEngine(StateDirectory, proDirectory),
            source, selectedResource.Target, targets, Path.Combine(StateDirectory, "artwork-collections.json"), selectedResource.Shared);
        page.ShowCollections(collections);
        cardPage = page;
        page.BusyChanged += UpdateButtons;
        Navigate(pageButton, page);
    }

    private void ShowPerformances()
    {
        if (activePage == performances && performancePage is not null) return;
        if (install is null || proDirectory is null)
            throw new InvalidOperationException("请先在设置中确认 Master Duel 和 MDPro3 的目录。");
        var resource = CurrentResources ?? throw new InvalidOperationException("请先设置资源主账号。");
        var source = GameResources.Cache(install, resource.MainFolder);
        var account = accounts.SelectedItem as Account;
        var folder = account is null ? null : FolderFor(account.Id);
        var cache = folder is null || SharedCache.HasBackup(install, folder) ? null : GameResources.Cache(install, folder);
        cardPage?.Dispose();
        cardPage = null;
        performancePage?.Dispose();
        var page = new PerformancePage(new CardEngine(StateDirectory, proDirectory), source,
            cache, account is null ? null : AccountLabel(account));
        performancePage = page;
        page.BusyChanged += UpdateButtons;
        Navigate(performances, page);
        _ = page.StartAsync();
    }

    private void Navigate(Button button, Control page)
    {
        var old = content.Controls.Count > 0 ? content.Controls[0] : null;
        if (old == page && activePage == button) return;
        content.SuspendLayout();
        if (old != page)
        {
            content.Controls.Clear();
            if (old is not null && old != accountContent && old != cardPage && old != royalPage && old != performancePage) old.Dispose();
            content.Controls.Add(page);
        }
        if (activePage is not null) { activePage.BackColor = Ui.Rail; activePage.ForeColor = Ui.RailText; }
        button.BackColor = Ui.RailSelected;
        button.ForeColor = Ui.Accent;
        activePage = button;
        AcceptButton = page == accountContent ? launch : null;
        content.ResumeLayout();
    }

    private void ClearCardPage()
    {
        cardPage?.Dispose();
        cardPage = null;
        performancePage?.Dispose();
        performancePage = null;
        royalPage?.Dispose();
        royalPage = null;
    }

    private void Execute(Action action)
    {
        if (busy) return;
        try { action(); }
        catch (Exception error) { status.Text = error.Message; Navigate(accountPage, accountContent); }
        finally { UpdateButtons(); }
    }

    private void UpdateButtons()
    {
        var pending = install is not null && new SteamSession(install, StateDirectory).CanRecover;
        launch.Enabled = switchSteam.Enabled = !busy && !pending && install is not null
            && accounts.SelectedItem is Account { Remembered: true };
        recover.Visible = pending;
        recover.Enabled = !busy;
        var editing = busy || cardPage?.Busy == true || royalPage?.Busy == true || performancePage?.Busy == true;
        accountPage.Enabled = preferences.Enabled = refresh.Enabled = accounts.Enabled = !editing;
        artwork.Enabled = artworkCollections.Enabled = royalFinish.Enabled = performances.Enabled = !editing && !pending;
        UpdateAccountDetails(editing);
        accounts.Redraw();
    }
}

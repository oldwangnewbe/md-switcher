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

internal sealed record Settings(string? Steam = null, string? Game = null, string? MDPro3 = null, Dictionary<string, ResourceSettings>? Resources = null);

internal sealed class MainWindow : Form
{
    private static readonly string StateDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MD Switcher");
    private static readonly string SettingsFile = Path.Combine(StateDirectory, "installation.json");
    private Settings settings = new();
    private Installation? install;
    private string? proDirectory;
    private readonly Label subtitle = Ui.Label("Steam · Master Duel", true);
    private readonly Label status = Ui.Label("", true);
    private readonly ListBox accounts = new()
    {
        Dock = DockStyle.Fill, IntegralHeight = false, DrawMode = DrawMode.OwnerDrawFixed,
        BorderStyle = BorderStyle.None, BackColor = Ui.Surface,
    };
    private readonly Button launch = Ui.Button("启动 MD", primary: true);
    private readonly Button switchSteam = Ui.Button("仅切换 Steam");
    private readonly Button recover = Ui.Button("恢复登录设置");
    private readonly Button refresh = Ui.Button("刷新账号");
    private readonly Button preferences = Ui.Button("设置");
    private readonly Button artwork = Ui.Button("卡片搜索 · 异画");
    private bool busy;

    public MainWindow()
    {
        Text = "MD 换号器 · Windows 0.2";
        Ui.Style(this);
        ClientSize = new Size(760, 500);
        MinimumSize = new Size(650, 460);
        StartPosition = FormStartPosition.CenterScreen;

        var body = Ui.Stack(SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        body.Padding = new Padding(22);
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, Margin = new(0, 0, 0, 18) };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var brand = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize);
        brand.AutoSize = true;
        var title = Ui.Label("MD 换号器");
        title.Font = new Font(Font.FontFamily, 21, FontStyle.Bold);
        subtitle.Margin = new(4, 6, 4, 3);
        brand.Controls.Add(title, 0, 0);
        brand.Controls.Add(subtitle, 0, 1);
        header.Controls.Add(brand, 0, 0);
        header.Controls.Add(Ui.Row(artwork, preferences), 1, 0);
        body.Controls.Add(header, 0, 0);

        var accountCard = Ui.Stack(SizeType.AutoSize, SizeType.Percent);
        accountCard.BackColor = Ui.Surface;
        accountCard.Padding = new Padding(13, 9, 13, 12);
        var accountHeader = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2 };
        accountHeader.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        accountHeader.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var accountsTitle = Ui.Label("Steam 账号");
        accountsTitle.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        accountsTitle.Anchor = AnchorStyles.Left;
        accountHeader.Controls.Add(accountsTitle, 0, 0);
        accountHeader.Controls.Add(refresh, 1, 0);
        accountCard.Controls.Add(accountHeader, 0, 0);
        accounts.Margin = new(0, 9, 0, 0);
        accounts.ItemHeight = Scale(53);
        accountCard.Controls.Add(accounts, 0, 1);
        body.Controls.Add(accountCard, 0, 1);

        var footer = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize);
        footer.AutoSize = true;
        status.MaximumSize = new(675, 0);
        status.Margin = new(3, 12, 3, 10);
        footer.Controls.Add(status, 0, 0);
        var actions = Ui.Row(launch, switchSteam, recover);
        actions.FlowDirection = FlowDirection.RightToLeft;
        footer.Controls.Add(actions, 0, 1);
        body.Controls.Add(footer, 0, 2);
        Controls.Add(body);
        AcceptButton = launch;

        Shown += (_, _) => Execute(() =>
        {
            accounts.ItemHeight = Scale(53);
            LoadSettings();
            RefreshInstall();
        });
        refresh.Click += (_, _) => Execute(() => RefreshInstall());
        preferences.Click += (_, _) => Execute(ShowSettings);
        artwork.Click += (_, _) => Execute(ShowArtwork);
        accounts.DrawItem += DrawAccount;
        DpiChanged += (_, _) => accounts.ItemHeight = Scale(53);
        accounts.SelectedIndexChanged += (_, _) => UpdateButtons();
        launch.Click += async (_, _) => await RunAsync(launch: true);
        switchSteam.Click += async (_, _) => await RunAsync(launch: false);
        recover.Click += (_, _) => Execute(() =>
        {
            if (install is null) return;
            new SteamSession(install, StateDirectory).Recover();
            RefreshInstall("Steam 登录设置已恢复。");
        });
        FormClosing += (_, args) => { if (busy) args.Cancel = true; };
        UpdateButtons();
    }

    private int Scale(int pixels) => (pixels * DeviceDpi + 48) / 96;

    private void DrawAccount(object? sender, DrawItemEventArgs item)
    {
        if (item.Index < 0 || accounts.Items[item.Index] is not Account account) return;
        var selected = (item.State & DrawItemState.Selected) != 0;
        var bounds = item.Bounds;
        using var background = new SolidBrush(selected ? Ui.Highlight : item.Index % 2 == 0 ? Ui.Background : Ui.Surface);
        item.Graphics.FillRectangle(background, bounds.X, bounds.Y, bounds.Width, bounds.Height - Scale(3));
        if (selected)
        {
            using var stripe = new SolidBrush(Ui.Accent);
            item.Graphics.FillRectangle(stripe, bounds.X, bounds.Y, Scale(3), bounds.Height - Scale(3));
        }

        var label = CurrentResources?.MainAccount == account.Id ? "资源主账号"
            : !account.Remembered ? "需先登录" : account.Preferred ? "默认登录" : "";
        var left = bounds.X + Scale(13);
        var width = Math.Max(0, bounds.Width - Scale(122));
        var name = account.Persona.Length == 0 ? account.Name : account.Persona;
        using var strong = new Font(Font.FontFamily, Font.Size + 1, FontStyle.Bold);
        var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(item.Graphics, name, strong, new Rectangle(left, bounds.Y + Scale(5), width, Scale(24)), Ui.Text, flags);
        TextRenderer.DrawText(item.Graphics, account.Name, Font, new Rectangle(left, bounds.Y + Scale(26), width, Scale(18)), Ui.Muted, flags);
        TextRenderer.DrawText(item.Graphics, label, Font,
            new Rectangle(bounds.Right - Scale(105), bounds.Y, Scale(91), bounds.Height - Scale(3)),
            selected ? Ui.Accent : Ui.Muted, flags | TextFormatFlags.Right);
        if ((item.State & DrawItemState.Focus) != 0) item.DrawFocusRectangle();
    }

    private void LoadSettings()
    {
        if (File.Exists(SettingsFile))
            settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsFile)) ?? new();
    }

    private void RefreshInstall(string? message = null)
    {
        var selected = (accounts.SelectedItem as Account)?.Id;
        install = null;
        accounts.Items.Clear();
        install = Installation.Find(settings.Steam, settings.Game, strict: settings.Steam is not null && settings.Game is null
            && File.Exists(Path.Combine(settings.Steam, "steam.exe")));
        proDirectory = Installation.FindMDPro3(settings.MDPro3, install);
        subtitle.Text = install is null ? "尚未找到 Steam 版 Master Duel"
            : proDirectory is null ? "Master Duel 已连接 · 可在设置中选择 MDPro3"
            : "Master Duel 已连接   ·   MDPro3 已连接";
        if (install is not null)
        {
            var saved = SteamSession.ReadAccounts(install);
            accounts.Items.AddRange(saved);
            accounts.SelectedItem = saved.FirstOrDefault(account => account.Id == selected)
                ?? saved.FirstOrDefault(account => account.Preferred && account.Remembered)
                ?? saved.FirstOrDefault(account => account.Remembered);
        }
        status.Text = message ?? (install is null ? "请选择 Steam 和 Master Duel 的安装目录。"
            : accounts.Items.Count == 0 ? "请先在 Steam 中登录账号并记住登录，再点「刷新账号」。"
            : "请选择账号。Steam 已登录所选账号时，可以直接启动游戏。");
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
        var folder = Pick(main ? "请选择该主账号的 LocalData 子文件夹"
            : "请选择该小号的 LocalData 子文件夹", GameResources.Root(install));
        if (folder is null) return;
        var name = GameResources.Identify(install, folder);
        var mappings = new Dictionary<ulong, string>(current?.Accounts ?? []);
        if (mappings.Any(pair => pair.Key != account.Id && pair.Value.Equals(name, StringComparison.OrdinalIgnoreCase))
            || !main && name.Equals(current!.MainFolder, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("这个目录已绑定给另一个账号。");
        if (main) mappings.Remove(account.Id);
        else mappings[account.Id] = name;
        var resource = main ? new ResourceSettings(account.Id, name, mappings) : current! with { Accounts = mappings };
        var byGame = new Dictionary<string, ResourceSettings>(settings.Resources ?? []);
        byGame[install.Game.ToUpperInvariant()] = resource;
        SaveAndRefresh(settings with { Resources = byGame });
        status.Text = main ? "已设置主账号资源。" : "已绑定小号资源。下次点「启动 MD」时会自动复用。";
    }

    private void ShowSettings()
    {
        using var dialog = new Form
        {
            Text = "设置 · 安装目录与游戏资源", ClientSize = new Size(715, 360),
            MinimumSize = new Size(610, 380), StartPosition = FormStartPosition.CenterParent,
        };
        Ui.Style(dialog);
        var layout = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent);
        layout.Padding = new Padding(18);
        var title = Ui.Label("安装目录");
        title.Font = new Font(dialog.Font.FontFamily, 15, FontStyle.Bold);
        layout.Controls.Add(title, 0, 0);

        var paths = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3, RowCount = 3 };
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        paths.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var steamPath = PathLabel();
        var gamePath = PathLabel();
        var proPath = PathLabel();
        var detect = Ui.Button("重新检测");
        var reset = Ui.Button("恢复自动检测");
        var bindMain = Ui.Button("设为资源主账号…");
        var bindAlt = Ui.Button("绑定小号资源…");
        var feedback = Ui.Label("", true);
        AddPath(0, "Steam", steamPath, ChooseSteam);
        AddPath(1, "Master Duel", gamePath, ChooseGame);
        AddPath(2, "MDPro3", proPath, ChoosePro);
        layout.Controls.Add(paths, 0, 1);
        detect.Click += (_, _) => Change(() => RefreshInstall());
        reset.Click += (_, _) => Change(() => SaveAndRefresh(new Settings(Resources: settings.Resources)));
        bindMain.Click += (_, _) => Change(() => BindResources(main: true));
        bindAlt.Click += (_, _) => Change(() => BindResources(main: false));
        layout.Controls.Add(Ui.Row(detect, reset, bindMain, bindAlt), 0, 2);

        feedback.Margin = new(3, 12, 3, 3);
        feedback.MaximumSize = new(635, 0);
        layout.Controls.Add(feedback, 0, 3);
        dialog.Controls.Add(layout);
        Update();
        dialog.ShowDialog(this);

        static Label PathLabel() => new()
        {
            Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = Ui.Muted, TextAlign = ContentAlignment.MiddleLeft,
        };

        void AddPath(int row, string name, Label value, Action select)
        {
            var label = Ui.Label(name);
            label.Anchor = AnchorStyles.Left;
            var button = Ui.Button("选择…");
            button.Click += (_, _) => Change(select);
            paths.Controls.Add(label, 0, row);
            paths.Controls.Add(value, 1, row);
            paths.Controls.Add(button, 2, row);
        }

        void Change(Action action)
        {
            Execute(action);
            Update();
            feedback.Text = status.Text;
        }

        void Update()
        {
            steamPath.Text = install?.Steam ?? settings.Steam ?? "尚未找到";
            gamePath.Text = install?.Game ?? "尚未找到 Steam 中已安装的游戏";
            proPath.Text = proDirectory ?? "尚未找到 · 可手动选择";
            var selected = accounts.SelectedItem as Account;
            var mappings = CurrentResources;
            bindMain.Enabled = install is not null && selected is not null;
            bindAlt.Enabled = bindMain.Enabled && mappings is not null && selected!.Id != mappings.MainAccount;
            feedback.Text = selected is null ? "在主界面选中 Steam 账号后，可绑定它的游戏资源。"
                : $"当前选择  {selected.Persona}   ·   绑定时请选择游戏 LocalData 下对应的账号文件夹。";
        }
    }

    private void ShowArtwork()
    {
        if (install is null || proDirectory is null)
            throw new InvalidOperationException("请先在设置中确认 Master Duel 和 MDPro3 的目录。");
        var resource = CurrentResources ?? throw new InvalidOperationException(
            "先在主界面选中大号，然后打开「设置 → 设为资源主账号」，绑定下载完整的游戏资源。");
        var source = GameResources.Cache(install, resource.MainFolder);
        var bound = accounts.Items.Cast<Account>().Select(account =>
        {
            var folder = account.Id == resource.MainAccount ? resource.MainFolder : resource.Accounts.GetValueOrDefault(account.Id);
            return (account.Id, Target: folder is null ? null : new ArtworkTarget(
                account.Persona.Length > 0 ? account.Persona : account.Name, folder));
        }).ToArray();
        var targets = bound.Select(entry => entry.Target).OfType<ArtworkTarget>().ToArray();
        if (targets.Select(target => target.Folder).Distinct(StringComparer.OrdinalIgnoreCase).Count() != targets.Length)
            throw new InvalidOperationException("有多个账号绑定了同一个目录，请先检查资源绑定。");
        var selected = (accounts.SelectedItem as Account)?.Id;
        using var window = new ArtworkWindow(install, new CardEngine(StateDirectory, proDirectory),
            source, bound.FirstOrDefault(entry => entry.Id == selected).Target, targets);
        window.ShowDialog(this);
    }

    private void Execute(Action action)
    {
        if (busy) return;
        try { action(); }
        catch (Exception error) { status.Text = error.Message; UpdateButtons(); }
    }

    private void UpdateButtons()
    {
        var pending = install is not null && new SteamSession(install, StateDirectory).CanRecover;
        launch.Enabled = switchSteam.Enabled = !busy && !pending && install is not null
            && accounts.SelectedItem is Account { Remembered: true };
        recover.Visible = pending;
        recover.Enabled = !busy;
        preferences.Enabled = refresh.Enabled = accounts.Enabled = !busy;
        artwork.Enabled = !busy && !pending;
        accounts.Invalidate();
    }
}

using System.Diagnostics;
using System.Text.Json;

namespace MDSwitcher;

internal sealed partial class MainWindow
{
    private readonly Label accountCount = Ui.Label("", true);
    private readonly Label profileName = Ui.Field("选择一个账号", 33);
    private readonly Label profileSteam = Ui.Field("—");
    private readonly Label profileFolder = Ui.Field("—");
    private readonly Label steamState = Ui.Field("", 20);
    private readonly Label resourceTitle = Ui.Label("");
    private readonly Label resourceHint = Ui.Label("", true);
    private readonly Button rename = Ui.Button("改备注");
    private readonly Button resourcePrimary = Ui.Button("", primary: true);
    private readonly Button resourceMore = Ui.Button("更多 ▾");
    private readonly ToolTip tips = new();
    private Action? resourceAction;
    private ulong? activeSteam;
    private readonly HashSet<ulong> sharedAccounts = [];

    private TableLayoutPanel BuildFrame()
    {
        var sidebar = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize,
            SizeType.Percent, SizeType.AutoSize, SizeType.AutoSize);
        sidebar.BackColor = Ui.Rail;
        sidebar.Padding = new Padding(15, 19, 15, 15);
        var brand = Ui.Heading("决斗匣", Font, 15);
        brand.Margin = new(5, 5, 0, 2);
        var edition = Ui.Label("DuelShelf");
        edition.ForeColor = Ui.RailText;
        edition.Font = new Font(Font.FontFamily, 8);
        edition.Margin = new(6, 0, 0, 23);
        if (Icon is not null)
        {
            var picture = new PictureBox
            {
                Image = Icon.ToBitmap(), Size = new(38, 38), SizeMode = PictureBoxSizeMode.Zoom, Margin = new(4, 0, 0, 5),
            };
            picture.Disposed += (_, _) => picture.Image?.Dispose();
            sidebar.Controls.Add(picture, 0, 0);
        }
        sidebar.Controls.Add(brand, 0, 1);
        sidebar.Controls.Add(edition, 0, 2);
        var links = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize);
        links.AutoSize = true;
        var navigation = new[] { accountPage, artwork, preferences, artworkCollections, royalFinish };
        for (var i = 0; i < navigation.Length; i++)
        {
            var button = (RoundedButton)navigation[i];
            button.NavIcon = i + 1;
            button.Dock = DockStyle.Fill;
            button.TextAlign = ContentAlignment.MiddleLeft;
            button.MinimumSize = new(0, 38);
            button.Margin = new(0, 0, 0, 6);
            button.BackColor = Ui.Rail;
            button.ForeColor = Ui.RailText;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Ui.RailSelected;
        }
        links.Controls.Add(accountPage, 0, 0);
        links.Controls.Add(artwork, 0, 1);
        links.Controls.Add(artworkCollections, 0, 2);
        links.Controls.Add(royalFinish, 0, 3);
        sidebar.Controls.Add(links, 0, 3);
        sidebar.Controls.Add(preferences, 0, 5);
        var version = Ui.Label($"v{typeof(MainWindow).Assembly.GetName().Version?.ToString(3)}");
        version.ForeColor = Ui.RailText;
        version.Margin = new(10, 8, 0, 0);
        sidebar.Controls.Add(version, 0, 6);

        var frame = Columns(152);
        var rail = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = new(0, 0, 1, 0), BackColor = Ui.Border };
        rail.Controls.Add(sidebar);
        frame.Controls.Add(rail, 0, 0);
        frame.Controls.Add(content, 1, 0);
        return frame;
    }

    private TableLayoutPanel BuildAccounts()
    {
        var body = Ui.Stack(SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        body.Padding = new(22, 18, 22, 14);
        body.Controls.Add(PageHeading("账号切换", subtitle), 0, 0);

        var columns = Columns(57, SizeType.Percent);
        columns.ColumnStyles[1].Width = 43;
        var list = Ui.Stack(SizeType.AutoSize, SizeType.Percent);

        refresh.Text = "刷新";
        var heading = Ui.Heading("Steam 账号", Font, 12);
        heading.Margin = new(3, 4, 8, 4);
        accountCount.Margin = new(3, 7, 3, 4);
        list.Controls.Add(SideBySide(Ui.Row(heading, accountCount), refresh), 0, 0);
        accounts.Margin = new(0, 8, 0, 0);
        list.Controls.Add(accounts, 0, 1);
        var accountCard = Card(list, new(13, 12, 13, 11));
        accountCard.Margin = new(0, 0, 12, 0);
        columns.Controls.Add(accountCard, 0, 0);
        columns.Controls.Add(BuildAccountInspector(), 1, 0);
        body.Controls.Add(columns, 0, 1);

        var actions = Ui.Row(recover, switchSteam, launch);
        actions.Anchor = AnchorStyles.Right;
        actions.Dock = DockStyle.None;
        steamState.ForeColor = Ui.Muted;
        status.ForeColor = Ui.Muted;
        status.Margin = new(3, 0, 3, 0);
        status.Visible = false;
        status.TextChanged += (_, _) =>
        {
            status.Visible = status.Text.Length > 0;
            steamState.Visible = status.Text.Length == 0;
            tips.SetToolTip(status, status.Text);
        };
        var footerText = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize);
        footerText.AutoSize = true;
        footerText.Controls.Add(status, 0, 0);
        footerText.Controls.Add(steamState, 0, 1);
        var footer = SideBySide(footerText, actions);
        footer.Margin = new(0, 10, 0, 0);
        body.Controls.Add(footer, 0, 2);
        tips.SetToolTip(switchSteam, "只登录这个账号，留在 Steam。");
        tips.SetToolTip(launch, "启动 Master Duel；Steam 登录的是其他账号时会先切换。");
        return body;
    }

    private Control BuildAccountInspector()
    {
        var detail = Ui.Stack(SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        var title = Ui.Heading("账号详情", Font, 12);
        title.Margin = new(3, 5, 0, 8);
        detail.Controls.Add(SideBySide(title, rename), 0, 0);

        var facts = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize,
            SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize);
        facts.Dock = DockStyle.Top;
        facts.AutoSize = true;
        facts.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        profileName.Font = new Font(Font.FontFamily, 17, FontStyle.Bold);
        profileName.Margin = new(3, 6, 3, 4);
        facts.Controls.Add(profileName, 0, 0);
        facts.Controls.Add(DetailField("Steam 登录名", profileSteam), 0, 1);
        facts.Controls.Add(DetailField("LocalData 目录", profileFolder), 0, 2);
        var divider = new Panel { BackColor = Ui.Border, Dock = DockStyle.Fill, Height = 1, Margin = new(3, 9, 3, 11) };
        facts.Controls.Add(divider, 0, 3);

        resourceTitle.Font = new Font(Font.FontFamily, 11, FontStyle.Bold);
        resourceTitle.Margin = new(3, 0, 3, 4);
        resourceHint.MaximumSize = new(246, 0);
        resourceHint.Margin = new(3, 0, 5, 8);
        facts.Controls.Add(resourceTitle, 0, 4);
        facts.Controls.Add(resourceHint, 0, 5);

        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Margin = Padding.Empty };
        scroll.Controls.Add(facts);
        detail.Controls.Add(scroll, 0, 1);
        detail.Controls.Add(Ui.Row(resourcePrimary, resourceMore), 0, 2);
        return Card(detail, new(14, 12, 14, 10));
    }

    private static Control DetailField(string title, Label value)
    {
        var row = Columns(128);
        row.AutoSize = true;
        row.RowStyles[0].SizeType = SizeType.AutoSize;
        row.Margin = new(0, 0, 0, 2);
        var key = Ui.Field(title);
        key.ForeColor = Ui.Muted;
        value.Margin = new(0, 0, 2, 0);
        row.Controls.Add(key, 0, 0);
        row.Controls.Add(value, 1, 0);
        return row;
    }

    private static RoundedPanel Card(TableLayoutPanel inside, Padding padding, bool autoSize = false)
    {
        var card = new RoundedPanel { BackColor = Ui.Surface, Dock = autoSize ? DockStyle.Top : DockStyle.Fill,
            AutoSize = autoSize, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = Padding.Empty, Padding = padding };
        inside.Dock = autoSize ? DockStyle.Top : DockStyle.Fill;
        card.Controls.Add(inside);
        return card;
    }

    private Control PageHeading(string title, Label description)
    {
        var header = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize);
        header.AutoSize = true;
        header.Margin = new(0, 0, 0, 15);
        var heading = Ui.Heading(title, Font, 24);
        heading.Margin = new(1, 0, 0, 2);
        description.Margin = new(3, 2, 3, 0);
        header.Controls.Add(heading, 0, 0);
        header.Controls.Add(description, 0, 1);
        return header;
    }

    private static TableLayoutPanel Columns(float left, SizeType kind = SizeType.Absolute)
    {
        var table = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty,
        };
        table.RowStyles.Add(new(SizeType.Percent, 100));
        table.ColumnStyles.Add(new(kind, left));
        table.ColumnStyles.Add(new(SizeType.Percent, 100));
        return table;
    }

    private static TableLayoutPanel SideBySide(Control left, Control right)
    {
        var table = Columns(100, SizeType.Percent);
        table.AutoSize = true;
        table.RowStyles[0].SizeType = SizeType.AutoSize;
        table.ColumnStyles[1].SizeType = SizeType.AutoSize;
        if (right is Button) right.Anchor = AnchorStyles.Right;
        table.Controls.Add(left, 0, 0);
        table.Controls.Add(right, 1, 0);
        return table;
    }

    private string AccountLabel(Account account) => settings.Aliases?.GetValueOrDefault(account.Id)
        ?? (account.Persona.Length == 0 ? account.Name : account.Persona);

    private string? FolderFor(ulong id)
    {
        var resources = CurrentResources;
        return resources?.MainAccount == id ? resources.MainFolder : resources?.Accounts.GetValueOrDefault(id);
    }

    private void DrawAccount(Graphics graphics, Rectangle card, Account account, bool selected, bool hover)
    {
        var avatar = new Rectangle(card.X + Scale(10), card.Y + Scale(15), Scale(37), Scale(37));
        var x = avatar.Right + Scale(10);
        var width = Math.Max(0, card.Right - x - Scale(9));
        var name = AccountLabel(account);
        var folder = FolderFor(account.Id);
        var online = activeSteam == account.Id;
        var badge = CurrentResources?.MainAccount == account.Id ? "资源主号"
            : online ? "已登录" : sharedAccounts.Contains(account.Id) ? "快速共享" : !account.Remembered ? "需登录" : "";
        var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        using var strong = new Font(Font.FontFamily, Font.Size + 1, FontStyle.Bold);
        using var small = new Font(Font.FontFamily, Font.Size - 0.75f);
        Ui.RoundedFill(graphics, card, Scale(10), selected ? Ui.Highlight : hover ? Ui.Background : Ui.Surface,
            selected ? Ui.Border : null);
        Ui.RoundedFill(graphics, avatar, Scale(10), selected ? Ui.Surface : Ui.Highlight);
        var initial = name.Length > 0 ? System.Globalization.StringInfo.GetNextTextElement(name).ToUpperInvariant() : "?";
        TextRenderer.DrawText(graphics, initial, strong, avatar, Ui.Accent, flags | TextFormatFlags.HorizontalCenter);

        var badgeWidth = badge.Length == 0 ? 0 : TextRenderer.MeasureText(graphics, badge, small).Width + Scale(12);
        TextRenderer.DrawText(graphics, name, strong,
            new Rectangle(x, card.Y + Scale(3), Math.Max(0, width - badgeWidth), Scale(22)), Ui.Text, flags);
        TextRenderer.DrawText(graphics, $"Steam  ·  {account.Name}", small,
            new Rectangle(x, card.Y + Scale(25), width, Scale(19)), Ui.Muted, flags);
        TextRenderer.DrawText(graphics, $"LocalData  ·  {folder ?? "未绑定"}", small,
            new Rectangle(x, card.Y + Scale(44), width, Scale(19)), Ui.Muted, flags);
        if (badgeWidth > 0)
        {
            var tag = new Rectangle(card.Right - badgeWidth - Scale(8), card.Y + Scale(5), badgeWidth, Scale(21));
            Ui.RoundedFill(graphics, tag, Scale(8), online && badge == "已登录" ? Ui.GreenTint : selected ? Ui.Surface : Ui.Highlight);
            TextRenderer.DrawText(graphics, badge, small, tag, badge == "已登录" ? Ui.Green : Ui.Accent,
                flags | TextFormatFlags.HorizontalCenter);
        }
    }

    private void UpdateAccountDetails(bool editing)
    {
        activeSteam = install is null ? null : new SteamSession(install, StateDirectory).ActiveAccount();
        var account = accounts.SelectedItem as Account;
        var resources = CurrentResources;
        var folder = account is null ? null : FolderFor(account.Id);
        var isMain = account is not null && resources?.MainAccount == account.Id;
        sharedAccounts.Clear();
        if (install is not null && resources is not null)
            foreach (var (id, boundFolder) in resources.Accounts)
                if (SharedCache.HasBackup(install, boundFolder)) sharedAccounts.Add(id);
        var shared = account is not null && sharedAccounts.Contains(account.Id);
        accountCount.Text = $"{accounts.Items.Count} 个";
        profileName.Text = account is null ? "选择一个账号" : AccountLabel(account);
        profileSteam.Text = account?.Name ?? "—";
        profileFolder.Text = folder ?? (account is null ? "—" : "未绑定");
        tips.SetToolTip(profileName, account is null ? "" : $"Steam 昵称：{account.Persona}");
        tips.SetToolTip(profileSteam, account?.Name ?? "");
        tips.SetToolTip(profileFolder, folder is null || install is null ? "" : Path.Combine(GameResources.Root(install), folder));
        rename.Enabled = !editing && account is not null;
        resourceMore.Visible = account is not null && folder is not null;
        resourceMore.Enabled = !editing;
        switchSteam.Visible = account is not null && activeSteam != account.Id;
        var active = accounts.Items.FirstOrDefault(item => item.Id == activeSteam);
        steamState.Text = account is null ? "" : activeSteam == account.Id ? "Steam 已登录所选账号，可直接启动。"
            : !account.Remembered ? "请先在 Steam 登录此账号并记住登录。"
            : active is not null ? $"Steam 当前登录：{active.Name}。启动时会先切换。"
            : "启动时会先登录所选账号。";
        tips.SetToolTip(steamState, steamState.Text);

        resourceAction = null;
        if (account is null)
            SetResource("游戏资源", "选中账号后，可以查看它的目录绑定和共享状态。");
        else if (resources is null)
            SetResource("先设置资源主号", "请选择已下载完整资源的账号，绑定它的游戏目录。",
                "设为资源主账号", () => BindResources(main: true));
        else if (isMain)
            SetResource("资源主账号", "快速共享的账号会使用这里的游戏资源和异画。");
        else if (folder is null)
            SetResource("尚未绑定目录", "用此账号进入游戏标题画面，退出后再绑定目录。",
                "绑定游戏目录", () => BindResources(main: false));
        else if (shared)
            SetResource("正在使用主号缓存", "游戏资源和异画与主号同步。恢复原缓存后可单独换异画。",
                "恢复原缓存", () => ChangeSharedCache(enable: false));
        else
            SetResource("正在使用独立缓存", "快速共享可跳过逐文件核对。原缓存会保留。",
                "快速共享主号缓存", () => ChangeSharedCache(enable: true));

        resourcePrimary.Visible = resourceAction is not null;
        resourceMore.Text = isMain ? "目录选项" : "更多";
        resourcePrimary.Enabled = !editing && install is not null && resourceAction is not null;

        void SetResource(string title, string note, string? actionText = null, Action? action = null)
        {
            resourceTitle.Text = title;
            resourceHint.Text = note;
            resourcePrimary.Text = actionText ?? "";
            resourceAction = action;
        }
    }

    private void ShowResourceOptions()
    {
        if (busy || install is not { } game || accounts.SelectedItem is not Account account || FolderFor(account.Id) is not { } folder)
            return;
        var main = CurrentResources?.MainAccount == account.Id;
        var shared = SharedCache.HasBackup(game, folder);
        var menu = new ChoiceMenu(resourceMore);
        menu.Add("在资源管理器中打开目录", () => Execute(() =>
            OpenFolder(Path.GetDirectoryName(GameResources.CacheLocation(game, folder))!)));
        if (!shared)
        {
            menu.Add("更改目录绑定…", () => Execute(() => BindResources(main)));
            if (!main)
                menu.Add("改为资源主账号…", () => Execute(() => BindResources(main: true)));
        }
        menu.ShowBelow();
    }

    private void RenameAccount()
    {
        if (accounts.SelectedItem is not Account account) return;
        using var dialog = new Form
        {
            Text = "账号备注", ClientSize = new(400, 150), StartPosition = FormStartPosition.CenterParent,
            FormBorderStyle = FormBorderStyle.FixedDialog, ShowInTaskbar = false, MaximizeBox = false, MinimizeBox = false,
        };
        dialog.SuspendLayout();
        Ui.Style(dialog);
        var layout = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        layout.Padding = new(15);
        var label = Ui.Label($"Steam 登录名：{account.Name}");
        var input = new TextBox { Text = settings.Aliases?.GetValueOrDefault(account.Id) ?? "", Dock = DockStyle.Top,
            BorderStyle = BorderStyle.None, MaxLength = 36, PlaceholderText = "例如：大号、闪刀小号", AccessibleName = "账号备注" };
        var hint = Ui.Label("备注仅保存在换号器。留空后显示 Steam 昵称。", true);
        var save = Ui.Button("保存", primary: true);
        save.DialogResult = DialogResult.OK;
        var cancel = Ui.Button("取消");
        cancel.DialogResult = DialogResult.Cancel;
        layout.Controls.Add(label, 0, 0);
        var inputCard = new RoundedPanel { BackColor = Ui.Surface, AutoSize = true, Dock = DockStyle.Fill,
            Corner = 8, Padding = new(9, 6, 9, 6), Margin = new(3, 6, 3, 6) };
        inputCard.Controls.Add(input);
        layout.Controls.Add(inputCard, 0, 1);
        layout.Controls.Add(hint, 0, 2);
        layout.Controls.Add(Ui.Row(save, cancel), 0, 3);
        dialog.Controls.Add(layout);
        dialog.AcceptButton = save;
        dialog.CancelButton = cancel;
        dialog.ActiveControl = input;
        dialog.ResumeLayout();
        if (dialog.ShowDialog(this) != DialogResult.OK) return;

        var aliases = new Dictionary<ulong, string>(settings.Aliases ?? []);
        var name = input.Text.Trim();
        if (name.Length == 0) aliases.Remove(account.Id);
        else aliases[account.Id] = name;
        var updated = settings with { Aliases = aliases };
        SteamSession.AtomicWrite(SettingsFile, JsonSerializer.Serialize(updated));
        settings = updated;
        ClearCardPage();
        UpdateButtons();
    }

    private static void OpenFolder(string path)
    {
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("找不到这个目录。请先在游戏中完成初始化。");
        using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }
}

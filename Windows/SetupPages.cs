namespace MDSwitcher;

internal sealed partial class MainWindow
{
    private sealed record FolderChoice(string Path, string Id, string? Owner, bool Available)
    {
        public override string ToString() => $"{Id}    ·    {Owner ?? "尚未绑定"}";
    }

    private string? PickResourceFolder(Installation game, Account account, bool main)
    {
        var root = GameResources.Root(game);
        var bound = CurrentResources;
        var owners = new Dictionary<string, ulong>(StringComparer.OrdinalIgnoreCase);
        if (bound is not null)
        {
            owners[bound.MainFolder] = bound.MainAccount;
            foreach (var (id, folder) in bound.Accounts) owners.TryAdd(folder, id);
        }

        var choices = new List<FolderChoice>();
        var list = new ChoiceList<FolderChoice>(46, PaintFolderChoice, choice => choice.ToString())
        { AccessibleName = "LocalData 文件夹", BackColor = Ui.Surface };
        if (Directory.Exists(root))
        {
            foreach (var path in Directory.EnumerateDirectories(root).Order(StringComparer.OrdinalIgnoreCase))
            {
                var name = Path.GetFileName(path);
                if (!GameResources.IsAccountFolder(name)) continue;
                var hasOwner = owners.TryGetValue(name, out var owner);
                if (!hasOwner && !File.Exists(GameResources.AssetPath(Path.Combine(path, "0000"), GameResources.Index)))
                    continue;
                var display = !hasOwner ? null : owner == account.Id ? "此账号当前绑定"
                    : accounts.Items.FirstOrDefault(item => item.Id == owner) is { } other
                        ? $"{AccountLabel(other)}（Steam：{other.Name}）" : $"已绑定 Steam ID {owner}";
                choices.Add(new FolderChoice(path, name, display, !hasOwner || owner == account.Id));
            }
        }

        using var dialog = new Form
        {
            Text = main ? "设置资源主账号" : "绑定游戏目录", ClientSize = new(530, 355),
            StartPosition = FormStartPosition.CenterParent, MinimumSize = new(500, 330),
            ShowInTaskbar = false, MaximizeBox = false, MinimizeBox = false,
        };
        dialog.SuspendLayout();
        Ui.Style(dialog);
        var layout = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        layout.Padding = new(15);
        var title = Ui.Heading(AccountLabel(account), Font, 16);
        title.MaximumSize = new(460, 0);
        var description = Ui.Label("", true);
        description.MaximumSize = new(470, 0);
        description.Margin = new(3, 3, 3, 9);
        var confirm = Ui.Button(main ? "设为资源主账号" : "确认绑定", primary: true);
        confirm.DialogResult = DialogResult.OK;
        var cancel = Ui.Button("取消");
        cancel.DialogResult = DialogResult.Cancel;
        var open = Ui.Button("打开 LocalData");
        open.Enabled = Directory.Exists(root);
        open.Click += (_, _) =>
        {
            try { OpenFolder(root); }
            catch (Exception error) { description.Text = error.Message; }
        };
        layout.Controls.Add(title, 0, 0);
        layout.Controls.Add(description, 0, 1);
        var choiceCard = new RoundedPanel { Dock = DockStyle.Fill, BackColor = Ui.Surface, Padding = new(7),
            Margin = new(0, 0, 0, 8) };
        choiceCard.Controls.Add(list);
        layout.Controls.Add(choiceCard, 0, 2);
        layout.Controls.Add(SideBySide(open, Ui.Row(confirm, cancel)), 0, 3);
        dialog.Controls.Add(layout);
        dialog.AcceptButton = confirm;
        dialog.CancelButton = cancel;
        list.SelectedIndexChanged += (_, _) => Update();
        var current = FolderFor(account.Id);
        list.SetItems(choices, choices.FirstOrDefault(candidate => candidate.Id.Equals(current, StringComparison.OrdinalIgnoreCase)));
        Update();
        dialog.ResumeLayout();
        return dialog.ShowDialog(this) == DialogResult.OK && list.SelectedItem is FolderChoice { Available: true } choice
            ? choice.Path : null;

        void Update()
        {
            confirm.Enabled = list.SelectedItem is FolderChoice { Available: true };
            var steam = $"Steam：{account.Name}。";
            description.Text = steam + (list.Items.Count == 0
                ? "还没找到可绑定的目录。用这个账号进入游戏标题画面后退出，再来绑定。"
                : list.SelectedItem is FolderChoice { Available: false }
                    ? "这个目录已绑定给另一个账号。请选择该账号自己的目录。"
                    : main ? "请选择这个账号已下载完整资源的文件夹。"
                    : "请选择这个账号的文件夹。可以打开 LocalData 对照。");
        }
    }

    private void PaintFolderChoice(Graphics graphics, Rectangle bounds, FolderChoice choice, bool selected, bool hover)
    {
        Ui.RoundedFill(graphics, bounds, Scale(8), selected ? Ui.Highlight : hover ? Ui.Background : Ui.Surface);
        var text = new Rectangle(bounds.X + Scale(11), bounds.Y, Math.Max(0, bounds.Width - Scale(20)), bounds.Height);
        TextRenderer.DrawText(graphics, choice.ToString(), Font, text, choice.Available ? Ui.Text : Ui.Muted,
            TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    private void ShowSettings()
    {
        var layout = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent);
        layout.Padding = new(22, 18, 22, 14);
        layout.Controls.Add(PageHeading("安装目录", Ui.Label("换电脑时，在这里重新检测或选择目录。", true)), 0, 0);

        var card = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize,
            SizeType.AutoSize, SizeType.AutoSize);
        card.AutoSize = true;
        var title = Ui.Heading("本机目录", Font, 12);
        title.Margin = new(3, 3, 3, 9);
        card.Controls.Add(title, 0, 0);
        var steam = Ui.Field("");
        var game = Ui.Field("");
        var pro = Ui.Field("");
        var detect = Ui.Button("重新检测", primary: true);
        var reset = Ui.Button("清除手动目录");
        var feedback = Ui.Label("", true);
        AddPath(1, "Steam", "读取已登录账号", steam, ChooseSteam);
        AddPath(2, "Master Duel", "定位游戏和 LocalData", game, ChooseGame);
        AddPath(3, "MDPro3", "卡片搜索和异画素材，可选", pro, ChoosePro);
        feedback.MaximumSize = new(615, 0);
        feedback.Margin = new(3, 8, 3, 4);
        card.Controls.Add(Ui.Row(detect, reset), 0, 4);
        card.Controls.Add(feedback, 0, 5);
        detect.Click += (_, _) => Change(() => RefreshInstall(), "已重新检测本机目录。");
        reset.Click += (_, _) => Change(() => SaveAndRefresh(settings with { Steam = null, Game = null, MDPro3 = null }),
            "已清除手动目录并重新检测。账号备注和原有绑定保留。");
        layout.Controls.Add(Card(card, new(15, 13, 15, 10), autoSize: true), 0, 1);

        var footer = Ui.Label("账号备注、LocalData 绑定和缓存共享都在「账号切换」页。", true);
        footer.Margin = new(3, 11, 3, 0);
        layout.Controls.Add(footer, 0, 2);
        layout.Scale(new SizeF(DeviceDpi / 96f, DeviceDpi / 96f));
        Update();
        Navigate(preferences, layout);

        void AddPath(int index, string name, string purpose, Label path, Action pick)
        {
            var row = Columns(152);
            row.AutoSize = true;
            row.RowStyles[0].SizeType = SizeType.AutoSize;
            var label = Ui.Field(name);
            label.Font = new Font(Font.FontFamily, 10, FontStyle.Bold);
            tips.SetToolTip(label, purpose);
            row.Controls.Add(label, 0, 0);
            path.ForeColor = Ui.Muted;
            var select = Ui.Button("选择目录…");
            select.Click += (_, _) => Change(pick);
            row.Controls.Add(SideBySide(path, select), 1, 0);
            var lane = new RoundedPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                BackColor = Ui.Background, Padding = new(10, 6, 6, 6), Margin = new(0, 0, 0, 8), Outline = null, Corner = 10 };
            row.Dock = DockStyle.Top;
            lane.Controls.Add(row);
            card.Controls.Add(lane, 0, index);
        }

        void Change(Action action, string message = "")
        {
            if (busy) return;
            try { action(); feedback.Text = message; }
            catch (Exception error) { feedback.Text = error.Message; }
            Update();
        }

        void Update()
        {
            SetPath(steam, install?.Steam ?? settings.Steam, "尚未找到");
            SetPath(game, install?.Game ?? settings.Game, "尚未找到 Steam 已安装的游戏");
            SetPath(pro, proDirectory ?? settings.MDPro3, "未连接，可手动选择");
            reset.Enabled = settings.Steam is not null || settings.Game is not null || settings.MDPro3 is not null;
        }

        void SetPath(Label label, string? path, string missing)
        {
            label.Text = path ?? missing;
            tips.SetToolTip(label, path);
        }
    }
}

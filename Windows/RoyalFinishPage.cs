namespace MDSwitcher;

internal sealed class RoyalFinishPage : UserControl
{
    private enum Mode { Search, Collection, Enabled }
    private sealed record CardRow(int Id, Card? Card)
    {
        public string Name => Card?.Name ?? $"卡片编号 {Id}";
        public IEnumerable<int> Ids => (Card?.MasterIDs ?? []).Append(Id).Where(RoyalFinishSettings.Supports);
    }

    private readonly CardEngine engine;
    private readonly string source;
    private readonly string collectionsFile;
    private readonly RoyalFinishSettings settings;
    private readonly ulong account;
    private readonly ulong[] accounts;
    private readonly ToolTip tips = new();
    private readonly Dictionary<string, Image?> thumbnails = new(StringComparer.OrdinalIgnoreCase);
    private readonly ChoiceList<CardRow> cards;
    private readonly TextBox search = new() { Dock = DockStyle.Top, BorderStyle = BorderStyle.None,
        PlaceholderText = "搜索卡名、系列或卡片编号", AccessibleName = "搜索卡片" };
    private readonly ChoiceDropDown<ArtworkCollection> collection = new("选择合集", item => item.Name)
        { Dock = DockStyle.Fill, DropDown = true, AccessibleName = "异画合集" };
    private readonly Button searchTab = Ui.Button("搜卡片");
    private readonly Button collectionTab = Ui.Button("按合集");
    private readonly Button enabledTab = Ui.Button("已开启");
    private readonly Button change = Ui.Button("设置镜碎", dropDown: true);
    private readonly Button changeGroup = Ui.Button("设置整组", dropDown: true);
    private readonly Button clear = Ui.Button("全部关闭");
    private readonly Button retry = Ui.Button("重试读取");
    private readonly Label summary = Ui.Field("正在读取本机卡库…");
    private readonly Label feedback = Ui.Field("");
    private readonly RoundedPanel searchBox;
    private readonly WorkspaceRows layout;
    private CardSearchEntry[] entries = [];
    private Dictionary<int, CardRow> rowsById = [];
    private HashSet<int> enabledIds;
    private Mode mode;
    private string? collectionError;
    private bool loaded;

    public bool Busy { get; private set; }
    public event Action? BusyChanged;

    public RoyalFinishPage(CardEngine engine, string source, string collectionsFile, RoyalFinishSettings settings,
                           ulong account, string accountName, ulong[] accounts)
    {
        this.engine = engine;
        this.source = source;
        this.collectionsFile = collectionsFile;
        this.settings = settings;
        this.account = account;
        this.accounts = accounts;
        enabledIds = new HashSet<int>(settings.Accounts.GetValueOrDefault(account) ?? []);
        Dock = DockStyle.Fill;
        AutoScaleMode = AutoScaleMode.None;

        layout = new WorkspaceRows(this, 49, 49, -1, 47);
        var target = Ui.Field(accountName);
        target.ForeColor = Ui.Muted;
        target.TextAlign = ContentAlignment.MiddleRight;
        target.AccessibleName = $"当前账号 · {accountName}";
        var tabs = Ui.WorkspaceBar(3, searchTab, collectionTab, enabledTab, target);
        layout.Controls.Add(tabs, 0, 0);

        searchBox = new RoundedPanel { BackColor = Ui.Surface, Dock = DockStyle.Fill, Corner = 8, Margin = Padding.Empty };
        searchBox.Controls.Add(search);
        var input = new Panel { Dock = DockStyle.Fill };
        input.Controls.Add(searchBox);
        input.Controls.Add(collection);
        var filters = Ui.WorkspaceBar(0, input, changeGroup);
        layout.Controls.Add(filters, 0, 1);

        var list = new WorkspaceRows(this, 26, -1);
        summary.ForeColor = Ui.Muted;
        summary.Margin = new(3, 0, 3, 0);
        list.Controls.Add(summary, 0, 0);
        cards = new ChoiceList<CardRow>(52, DrawCard, row => $"{row.Name}，{CardState(row)}")
            { BackColor = Ui.Surface, AccessibleName = "动态镜碎卡片" };
        list.Controls.Add(cards, 0, 1);
        var card = new RoundedPanel { BackColor = Ui.Surface, Dock = DockStyle.Fill, Margin = Padding.Empty };
        card.Controls.Add(list);
        layout.Controls.Add(card, 0, 2);

        feedback.ForeColor = Ui.Accent;
        var actions = Ui.WorkspaceBar(0, feedback, retry, clear, change);
        layout.Controls.Add(actions, 0, 3);
        Controls.Add(layout);
        Ui.AtDeviceDpi(this, dpi =>
        {
            int Dip(int value) => Ui.Dip(value, dpi);
            layout.Padding = new Padding(Dip(16), Dip(14), Dip(16), Dip(6));
            tabs.Margin = filters.Margin = new Padding(0, 0, 0, Dip(8));
            input.Margin = new Padding(0, Dip(3), 0, Dip(3));
            searchBox.Padding = new Padding(Dip(10), Dip(7), Dip(10), 0);
            card.Padding = new Padding(Dip(8));
            actions.Padding = new Padding(0, Dip(4), 0, 0);
            ClearThumbnails();
        });
        tips.SetToolTip(target, $"当前账号 · {accountName}\n保持换号器运行，从 Steam 启动游戏也会自动加载。效果仅在本机显示。");
        tips.SetToolTip(change, "为当前账号或所有 Steam 账号设置所选卡片。");
        feedback.TextChanged += (_, _) =>
        {
            tips.SetToolTip(feedback, feedback.Text);
            UpdateActions();
        };
        summary.TextChanged += (_, _) =>
        {
            tips.SetToolTip(summary, summary.Text);
            list.SetHeight(0, summary.Text.Length == 0 ? 0 : 26);
        };
        searchTab.Click += (_, _) => SelectMode(Mode.Search);
        collectionTab.Click += (_, _) => SelectMode(Mode.Collection);
        enabledTab.Click += (_, _) => SelectMode(Mode.Enabled);
        search.TextChanged += (_, _) => Filter();
        collection.SelectedIndexChanged += (_, _) => Filter();
        cards.SelectedIndexChanged += (_, _) => UpdateActions();
        change.Click += (_, _) => { if (cards.SelectedItem is { } selected) ShowActions(change, selected.Ids); };
        changeGroup.Click += (_, _) => ShowActions(changeGroup, CollectionRows().SelectMany(row => row.Ids));
        clear.Click += (_, _) => Save(enabledIds, enable: false, all: false);
        retry.Click += async (_, _) => await ReadCardsAsync();
        Load += async (_, _) => await ReadCardsAsync();
        SelectMode(Mode.Search);
    }

    public void ShowLoadResult(string message) => feedback.Text = message;

    public void ReloadCollections()
    {
        var prior = collection.SelectedItem?.Id;
        ArtworkCollection[] saved;
        collectionError = null;
        try { saved = ArtworkCollection.Load(collectionsFile); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            saved = [];
            collectionError = $"合集读取失败。{error.Message}";
        }
        collection.SetItems(saved, saved.FirstOrDefault(item => item.Id == prior) ?? saved.FirstOrDefault());
    }

    private async Task ReadCardsAsync()
    {
        if (Busy || loaded) return;
        Busy = true;
        BusyChanged?.Invoke();
        summary.Text = "正在读取本机卡库…";
        UpdateActions();
        try
        {
            var indexed = await Task.Run(() => engine.LoadCards(source).Where(card => card.Cid is int cid &&
                RoyalFinishSettings.Supports(cid)).Select(card => new CardSearchEntry(card)).ToArray());
            if (IsDisposed) return;
            entries = indexed;
            rowsById = entries.ToDictionary(entry => entry.Card.Cid!.Value, entry => new CardRow(entry.Card.Cid!.Value, entry.Card));
            loaded = true;
            ReloadCollections();
            Filter();
        }
        catch (Exception error)
        {
            if (!IsDisposed) summary.Text = $"卡库读取失败。{error.Message}";
        }
        finally
        {
            Busy = false;
            if (!IsDisposed) { UpdateActions(); BusyChanged?.Invoke(); }
        }
    }

    private string CardState(CardRow row) => row.Ids.All(enabledIds.Contains) ? "已开启"
        : row.Ids.Any(enabledIds.Contains) ? "部分开启" : "未开启";

    private void SelectMode(Mode next)
    {
        mode = next;
        foreach (var (button, value) in new[] { (searchTab, Mode.Search), (collectionTab, Mode.Collection), (enabledTab, Mode.Enabled) })
        {
            button.BackColor = next == value ? Ui.Highlight : Ui.Surface;
            button.ForeColor = next == value ? Ui.Accent : Ui.Text;
        }
        searchBox.Visible = next == Mode.Search;
        collection.Visible = next == Mode.Collection;
        layout.SetHeight(1, next == Mode.Enabled ? 0 : 49);
        Filter();
        UpdateActions();
    }

    private CardRow[] CollectionRows() => collection.SelectedItem is { } selected
        ? selected.Choices.Keys.Where(rowsById.ContainsKey).Select(id => rowsById[id]).OrderBy(row => row.Name).ToArray() : [];

    private void Filter()
    {
        if (!loaded) return;
        var query = CardSearchEntry.Normalize(search.Text);
        CardRow[] results;
        switch (mode)
        {
            case Mode.Collection:
                results = CollectionRows();
                summary.Text = collectionError ?? (results.Length == 0 ? "合集里没有卡片" : "");
                break;
            case Mode.Enabled:
                results = rowsById.Values.Where(row => row.Ids.Any(enabledIds.Contains)).OrderBy(row => row.Name).ToArray();
                var mapped = results.SelectMany(row => row.Ids).ToHashSet();
                results = [.. results, .. enabledIds.Except(mapped).Order().Select(id => new CardRow(id, null))];
                summary.Text = results.Length == 0 ? "当前账号未开启镜碎" : "";
                break;
            default:
                if (query.Length == 0)
                {
                    results = [];
                    summary.Text = "输入卡名或编号";
                    break;
                }
                var matches = entries.Select(entry => (entry.Card, Rank: entry.Rank(query))).Where(pair => pair.Rank >= 0)
                    .OrderBy(pair => pair.Rank).ThenBy(pair => pair.Card.Name).ToArray();
                results = matches.Take(150).Select(pair => rowsById[pair.Card.Cid!.Value]).ToArray();
                summary.Text = matches.Length > results.Length ? $"显示前 {results.Length} 张，可缩小搜索范围"
                    : matches.Length == 0 ? "没有匹配的卡片" : "";
                break;
        }
        var previous = cards.SelectedItem?.Id;
        cards.SetItems(results, results.FirstOrDefault(row => row.Id == previous) ?? results.FirstOrDefault());
    }

    private void UpdateActions()
    {
        retry.Visible = !loaded && !Busy;
        searchTab.Enabled = collectionTab.Enabled = enabledTab.Enabled = search.Enabled = collection.Enabled = !Busy && loaded;
        change.Visible = cards.SelectedItem is not null;
        change.Enabled = !Busy && cards.SelectedItem is not null;
        changeGroup.Visible = mode == Mode.Collection;
        changeGroup.Enabled = !Busy && CollectionRows().Length > 0;
        clear.Visible = mode == Mode.Enabled && enabledIds.Count > 0;
        clear.Enabled = !Busy && enabledIds.Count > 0;
        layout.SetHeight(3, !loaded && !Busy || cards.SelectedItem is not null || feedback.Text.Length > 0 ? 47 : 0);
    }

    private void ShowActions(Control anchor, IEnumerable<int> ids)
    {
        var selection = ids.Distinct().ToArray();
        if (selection.Length == 0) return;
        var menu = new ChoiceMenu(anchor);
        menu.Add("为当前账号开启", () => Save(selection, enable: true, all: false));
        menu.Add("为当前账号关闭", () => Save(selection, enable: false, all: false));
        menu.Add("为所有账号开启", () => Save(selection, enable: true, all: true));
        menu.Add("为所有账号关闭", () => Save(selection, enable: false, all: true));
        menu.ShowBelow();
    }

    private void Save(IEnumerable<int> ids, bool enable, bool all)
    {
        try
        {
            settings.Update(all ? accounts : [account], ids, enable);
            enabledIds = new HashSet<int>(settings.Accounts.GetValueOrDefault(account) ?? []);
            Filter();
            feedback.Text = enable ? "已开启 · 下次启动生效" : "已关闭 · 下次启动生效";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            feedback.Text = $"动态镜碎设置未保存。{error.Message}";
        }
    }

    private void DrawCard(Graphics graphics, Rectangle bounds, CardRow row, bool selected, bool hover)
    {
        int Dip(int pixels) => Ui.Dip(pixels, DeviceDpi);
        Ui.RoundedFill(graphics, bounds, Dip(8), selected ? Ui.Highlight : hover ? Ui.Background : Ui.Surface);
        var thumb = new Rectangle(bounds.X + Dip(9), bounds.Y + Dip(5), Dip(42), Dip(42));
        if (row.Card is { } card && engine.ThumbnailPath(card) is string path)
        {
            if (!thumbnails.TryGetValue(path, out var image))
            {
                if (thumbnails.Count >= 180) ClearThumbnails();
                try
                {
                    using var stream = File.OpenRead(path);
                    using var art = Image.FromStream(stream);
                    var scale = (double)thumb.Width / Math.Max(art.Width, art.Height);
                    image = new Bitmap(art, Math.Max(1, (int)(art.Width * scale)), Math.Max(1, (int)(art.Height * scale)));
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
                thumbnails[path] = image;
            }
            if (image is not null) graphics.DrawImageUnscaled(image, thumb.X + (thumb.Width - image.Width) / 2,
                thumb.Y + (thumb.Height - image.Height) / 2);
        }
        var state = CardState(row);
        var badge = new Rectangle(bounds.Right - Dip(79), bounds.Y + Dip(14), Dip(67), Dip(25));
        Ui.RoundedFill(graphics, badge, Dip(12), state == "未开启" ? Ui.Background : Ui.GreenTint);
        const TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis |
            TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(graphics, state, Font, badge, state == "未开启" ? Ui.Muted : Ui.Green, flags | TextFormatFlags.HorizontalCenter);
        var left = thumb.Right + Dip(10);
        var width = Math.Max(0, badge.Left - left - Dip(8));
        var secondary = row.Card?.ProName is string alias && alias != row.Name ? alias : null;
        TextRenderer.DrawText(graphics, row.Name, Font, new Rectangle(left, bounds.Y + Dip(5), width,
            secondary is null ? bounds.Height - Dip(10) : Dip(22)), Ui.Text, flags);
        if (secondary is not null)
            TextRenderer.DrawText(graphics, secondary, Font, new Rectangle(left, bounds.Y + Dip(26), width, Dip(20)), Ui.Muted, flags);
    }

    private void ClearThumbnails()
    {
        foreach (var image in thumbnails.Values) image?.Dispose();
        thumbnails.Clear();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { ClearThumbnails(); tips.Dispose(); }
        base.Dispose(disposing);
    }
}

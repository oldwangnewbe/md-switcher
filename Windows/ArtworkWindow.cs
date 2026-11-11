using System.Text;

namespace MDSwitcher;

internal sealed record ArtworkTarget(string Name, string Folder);

internal sealed class ArtworkWindow : Form
{
    private sealed record SearchEntry(Card Card, string[] Names, string[] Series);
    private sealed record Collection(string Name, string Term)
    {
        public override string ToString() => Name;
    }

    private readonly Installation install;
    private readonly CardEngine engine;
    private readonly string source;
    private readonly ArtworkTarget? target;
    private readonly ArtworkTarget[] targets;
    private SearchEntry[] entries = [];
    private Dictionary<string, GameResources.Entry> selectedIndex = [];
    private string? selectedCache;
    private bool busy;

    private readonly TextBox search = new() { PlaceholderText = "搜索卡名、系列或卡片编号", Dock = DockStyle.Fill };
    private readonly ComboBox collection = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 115 };
    private readonly CheckBox available = new() { Text = "仅有可替换异画", AutoSize = true, Margin = new(8, 6, 2, 2) };
    private readonly ListBox results = new() { Dock = DockStyle.Fill, IntegralHeight = false, BorderStyle = BorderStyle.FixedSingle };
    private readonly Label count = Ui.Label("正在读取本机卡库…", true);
    private readonly Label title = Ui.Label("选择一张卡");
    private readonly Label alternateName = Ui.Label("", true);
    private readonly Label notice = Ui.Label("", true);
    private readonly PictureBox preview = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Ui.Background };
    private readonly ComboBox options = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, DisplayMember = nameof(Option.Label) };
    private readonly CheckBox all = new() { Text = "应用到所有已绑定账号", AutoSize = true, Margin = new(3, 8, 3, 8) };
    private readonly Button apply = Ui.Button("应用异画", primary: true);
    private readonly Button restore = Ui.Button("恢复原画");
    private readonly Button retry = Ui.Button("重试读取");
    private sealed record Option(string Label, CardVariant Variant);

    public ArtworkWindow(Installation install, CardEngine engine, string source, ArtworkTarget? target, ArtworkTarget[] targets)
    {
        this.install = install;
        this.engine = engine;
        this.source = source;
        this.target = target;
        this.targets = targets;
        Ui.Style(this);
        Text = "卡片搜索 · 异画";
        ClientSize = new Size(890, 630);
        MinimumSize = new Size(775, 590);
        StartPosition = FormStartPosition.CenterParent;

        var layout = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        layout.Padding = new Padding(20);
        var headline = Ui.Label("异画");
        headline.Font = new Font(Font.FontFamily, 19, FontStyle.Bold);
        headline.Margin = new Padding(3, 0, 3, 12);
        layout.Controls.Add(headline, 0, 0);

        var filters = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3, Margin = new(0, 0, 0, 10) };
        filters.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        filters.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        filters.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        filters.Controls.Add(search, 0, 0);
        filters.Controls.Add(collection, 1, 0);
        filters.Controls.Add(available, 2, 0);
        layout.Controls.Add(filters, 0, 1);

        var columns = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 1, ColumnCount = 2, Margin = Padding.Empty };
        columns.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 46));
        columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 54));
        var list = Ui.Stack(SizeType.AutoSize, SizeType.Percent);
        count.Margin = new(3, 3, 3, 8);
        list.Controls.Add(count, 0, 0);
        list.Controls.Add(results, 0, 1);
        columns.Controls.Add(list, 0, 0);
        var detail = Ui.Stack(SizeType.AutoSize, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize);
        detail.BackColor = Ui.Surface;
        detail.Margin = new(14, 0, 0, 0);
        detail.Padding = new Padding(16);
        title.Font = new Font(Font.FontFamily, 14, FontStyle.Bold);
        title.MaximumSize = new(370, 0);
        alternateName.MaximumSize = new(370, 0);
        preview.Margin = new(3, 8, 3, 8);
        detail.Controls.Add(title, 0, 0);
        detail.Controls.Add(alternateName, 0, 1);
        detail.Controls.Add(preview, 0, 2);
        detail.Controls.Add(options, 0, 3);
        detail.Controls.Add(all, 0, 4);
        detail.Controls.Add(Ui.Row(apply, restore), 0, 5);
        columns.Controls.Add(detail, 1, 0);
        layout.Controls.Add(columns, 0, 2);
        notice.MaximumSize = new(690, 0);
        notice.Margin = new(3, 10, 3, 4);
        retry.Visible = false;
        layout.Controls.Add(Ui.Row(notice, retry), 0, 3);
        Controls.Add(layout);

        collection.Items.AddRange(new Collection[]
        {
            new("全部卡片", ""), new("闪刀姬", "闪刀"), new("烙印", "烙印"), new("黑魔导", "黑魔导")
        });
        collection.SelectedIndex = 0;
        results.Format += (_, args) =>
        {
            if (args.ListItem is Card card)
                args.Value = card.Replaceable ? $"{card.Name}   ·   {card.Variants.Length} 款" : card.Name;
        };
        results.FormattingEnabled = true;
        search.TextChanged += (_, _) => Filter();
        collection.SelectedIndexChanged += (_, _) => Filter();
        available.CheckedChanged += (_, _) => Filter();
        results.SelectedIndexChanged += (_, _) => ShowCard();
        options.SelectedIndexChanged += (_, _) => ShowPreview();
        all.CheckedChanged += (_, _) => UpdateButtons();
        apply.Click += async (_, _) => await EditAsync(restoreOriginal: false);
        restore.Click += async (_, _) => await EditAsync(restoreOriginal: true);
        retry.Click += async (_, _) => await LoadAsync();
        Shown += async (_, _) => await LoadAsync();
        FormClosing += (_, args) => { if (busy) args.Cancel = true; };
        FormClosed += (_, _) => { preview.Image?.Dispose(); };
        UpdateButtons();
    }

    private async Task LoadAsync()
    {
        busy = true;
        retry.Visible = false;
        notice.Text = "首次会建立索引，之后会读取本机缓存。";
        UpdateButtons();
        try
        {
            entries = await Task.Run(() => engine.LoadCards(source).Select(card => new SearchEntry(card,
                new[] { card.Id, card.MasterName ?? "", card.ProName ?? "" }
                    .Concat(card.Codes.Select(code => code.ToString()))
                    .Concat(card.MasterIDs.Select(id => id.ToString()))
                    .Concat(card.Cid is int cid ? [cid.ToString()] : [])
                    .Select(Normalize).Distinct().ToArray(),
                card.Series.Select(Normalize).ToArray())).ToArray());
            if (target is not null)
            {
                try
                {
                    var cache = GameResources.Cache(install, target.Folder);
                    selectedIndex = GameResources.ReadIndex(cache).Items.ToDictionary(entry => entry.Name);
                    selectedCache = cache;
                }
                catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
                {
                    selectedIndex = [];
                    selectedCache = null;
                }
            }
            notice.Text = target is null ? "所选账号尚未绑定资源，可在主界面的设置里绑定。"
                : $"当前账号  {target.Name} · 应用前请退出游戏。";
            Filter();
        }
        catch (Exception error)
        {
            count.Text = "卡库读取失败";
            notice.Text = error.Message;
            retry.Visible = true;
        }
        finally { busy = false; UpdateButtons(); }
    }

    private void Filter()
    {
        if (entries.Length == 0) return;
        var query = Normalize(search.Text);
        var term = Normalize((collection.SelectedItem as Collection)?.Term ?? "");
        var prior = (results.SelectedItem as Card)?.Id;
        var matches = entries.Where(entry =>
            (!available.Checked || entry.Card.Replaceable) &&
            (term.Length == 0 || entry.Series.Any(series => series.Contains(term, StringComparison.Ordinal)) ||
                entry.Names.Any(name => name.Contains(term, StringComparison.Ordinal))))
            .Select(entry => (entry.Card, Rank(entry, query))).Where(pair => pair.Item2 >= 0)
            .OrderBy(pair => pair.Item2).ThenByDescending(pair => pair.Card.Replaceable).ToArray();
        results.BeginUpdate();
        try
        {
            results.Items.Clear();
            results.Items.AddRange(matches.Take(200).Select(pair => pair.Card).ToArray());
            if (results.Items.Count > 0)
                results.SelectedItem = results.Items.Cast<Card>().FirstOrDefault(card => card.Id == prior) ?? results.Items[0];
        }
        finally { results.EndUpdate(); }
        count.Text = matches.Length > 200 ? $"找到 {matches.Length} 张 · 显示前 200 张" : $"找到 {matches.Length} 张";
        ShowCard();
    }

    private static int Rank(SearchEntry entry, string query)
    {
        if (query.Length == 0 || entry.Names.Contains(query, StringComparer.Ordinal)) return 0;
        if (entry.Series.Any(series => series.Contains(query, StringComparison.Ordinal))) return 1;
        if (entry.Names.Any(name => name.StartsWith(query, StringComparison.Ordinal))) return 2;
        return entry.Names.Any(name => name.Contains(query, StringComparison.Ordinal)) ? 3 : -1;
    }

    private static string Normalize(string input) =>
        new(input.Normalize(NormalizationForm.FormKC).ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    private void ShowCard()
    {
        options.Items.Clear();
        var card = results.SelectedItem as Card;
        title.Text = card?.Name ?? "选择一张卡";
        var alias = card?.ProName is string name && name != card.MasterName && card.MasterName is not null
            ? $"MDPro3  {name}\n" : "";
        alternateName.Text = alias + (card is null ? "" : card.Replaceable ? $"{card.Variants.Length} 款可替换异画"
            : card.Variants.Length == 0 ? "MDPro3 未找到异画" : "有异画，当前 Master Duel 资源里还找不到可替换的卡图");
        if (card is not null)
        {
            var applied = AppliedVariant(card);
            options.Items.AddRange(card.Variants.Select((variant, index) => new Option(
                $"异画 {index + 1}  ·  {variant.Id}{(variant.Id == applied ? "  ·  当前使用" : "")}", variant)).ToArray());
            if (applied is not null) alternateName.Text += $"  ·  已应用 {applied}";
        }
        if (options.Items.Count > 0) options.SelectedIndex = 0;
        else ShowPreview();
        UpdateButtons();
    }

    private int? AppliedVariant(Card card)
    {
        if (selectedCache is null || card.Path is null || !selectedIndex.TryGetValue(card.Path, out var entry)) return null;
        try { return ArtworkFiles.AppliedVariant(selectedCache, entry); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            return null;
        }
    }

    private void ShowPreview()
    {
        var previous = preview.Image;
        preview.Image = null;
        previous?.Dispose();
        if (options.SelectedItem is not Option option) return;
        try
        {
            using var stream = File.OpenRead(engine.ArtworkPath(option.Variant));
            using var image = Image.FromStream(stream);
            preview.Image = new Bitmap(image);
        }
        catch (Exception error) when (error is IOException or ArgumentException or InvalidDataException)
        {
            notice.Text = "无法读取异画预览。请检查 MDPro3 素材。";
        }
        UpdateButtons();
    }

    private void UpdateButtons()
    {
        var hasTarget = all.Checked ? targets.Length > 0 : target is not null;
        search.Enabled = collection.Enabled = available.Enabled = results.Enabled = options.Enabled = !busy;
        all.Enabled = !busy && targets.Length > 0;
        apply.Enabled = !busy && hasTarget && results.SelectedItem is Card { Replaceable: true } && options.SelectedItem is Option;
        restore.Enabled = !busy && hasTarget && results.SelectedItem is Card { Path: not null };
    }

    private async Task EditAsync(bool restoreOriginal)
    {
        if (busy || results.SelectedItem is not Card { Path: not null } card) return;
        var choice = restoreOriginal ? null : (options.SelectedItem as Option)?.Variant;
        if (!restoreOriginal && choice is null) return;
        var selected = all.Checked ? targets : target is null ? [] : [target];
        if (selected.Length == 0) return;
        busy = true;
        UpdateButtons();
        notice.Text = restoreOriginal ? "正在核对并恢复原画…" : "正在校验并应用异画…";
        try
        {
            notice.Text = await Task.Run(() =>
            {
                EnsureGameClosed();
                var failures = new List<string>();
                var ok = 0;
                foreach (var account in selected)
                {
                    try
                    {
                        var cache = GameResources.Cache(install, account.Folder);
                        var entry = GameResources.ReadIndex(cache).Items.FirstOrDefault(item => item.Name == card.Path)
                            ?? throw new IOException("该账号还没下载这张卡的资源。");
                        var original = ArtworkFiles.ReadOriginal(cache, entry);
                        var patch = choice is null ? null : engine.MakePatch(card, choice, original);
                        if (GameResources.ReadIndex(cache).Items.FirstOrDefault(item => item.Name == card.Path) != entry)
                            throw new IOException("游戏索引刚刚更新，请重新打开卡片搜索。");
                        ArtworkFiles.Apply(cache, entry, original, patch, choice?.Id, EnsureGameClosed);
                        ok++;
                    }
                    catch (Exception error) when (error is IOException or InvalidOperationException or InvalidDataException
                        or UnauthorizedAccessException or TimeoutException or System.Text.Json.JsonException)
                    {
                        failures.Add($"{account.Name}：{error.Message}");
                    }
                }
                var message = restoreOriginal ? $"{ok} 个账号已恢复原画。" : $"{ok} 个账号已应用异画。";
                return failures.Count == 0 ? message : $"{message} {string.Join("  ", failures)}";
            });
        }
        catch (Exception error) { notice.Text = error.Message; }
        finally
        {
            var variant = options.SelectedIndex;
            busy = false;
            ShowCard();
            if (variant >= 0 && variant < options.Items.Count) options.SelectedIndex = variant;
            UpdateButtons();
        }
    }

    private static void EnsureGameClosed()
    {
        if (SteamSession.GameRunning()) throw new InvalidOperationException("请先退出 Master Duel，再修改卡图。");
    }
}

namespace MDSwitcher;

internal sealed record ArtworkTarget(string Name, string Folder);

internal sealed partial class ArtworkPage : UserControl
{
    private sealed record Collection(string Name, string Term)
    {
        public override string ToString() => Name;
    }

    private readonly Installation install;
    private readonly CardEngine engine;
    private readonly string source;
    private readonly ArtworkTarget? target;
    private readonly ArtworkTarget[] targets;
    private readonly bool sharedTarget;
    private readonly CardThumbnails thumbnails;
    private readonly System.Windows.Forms.Timer searchDelay = new() { Interval = 120 };
    private string? previewPath;
    private bool loadingPreview;
    public bool Busy => busy;
    public event Action? BusyChanged;
    private CardSearchEntry[] entries = [];
    private Dictionary<string, GameResources.Entry> selectedIndex = [];
    private string? selectedCache;
    private bool busy;

    private readonly TextBox search = new() { PlaceholderText = "搜索卡名、系列或卡片编号", Dock = DockStyle.Top,
        BorderStyle = BorderStyle.None };
    private readonly ChoiceDropDown<Collection> collection = new("全部卡片", item => item.Name)
        { AutoSize = true, DropDown = true, AccessibleName = "卡片系列" };
    private readonly CheckBox available = new() { Text = "仅有可替换异画", AutoSize = true, Margin = new(8, 6, 2, 2) };
    private readonly CardResultList results = new() { Dock = DockStyle.Fill };
    private readonly Label count = Ui.Field("正在读取本机卡库…", 24);
    private readonly Label title = Ui.Field("", 26);
    private readonly Label notice = Ui.Field("", 23);
    private readonly ToolTip tips = new();
    private readonly PictureBox preview = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Ui.Background };
    private readonly Label previewStatus = new() { Text = "暂无预览", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter,
        BackColor = Ui.Background, ForeColor = Ui.Muted, Visible = false };
    private readonly ChoiceDropDown<Option> options = new("选择卡图", item => item.Label)
        { DropDown = true, Dock = DockStyle.Fill, AccessibleName = "卡图版本" };
    private readonly CheckBox all = new() { Text = "所有账号", AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly Button apply = Ui.Button("应用异画", primary: true);
    private readonly Button restore = Ui.Button("恢复原画");
    private readonly Button retry = Ui.Button("重试读取");
    private sealed record Option(string Label, CardVariant? Variant);

    public ArtworkPage(Installation install, CardEngine engine, string source, ArtworkTarget? target, ArtworkTarget[] targets,
                       string collectionsFile, bool sharedTarget = false)
    {
        this.install = install;
        this.engine = engine;
        this.source = source;
        this.target = target;
        this.targets = targets;
        this.collectionsFile = collectionsFile;
        this.sharedTarget = sharedTarget;
        thumbnails = new CardThumbnails(() => results.Invalidate());
        Dock = DockStyle.Fill;
        AutoScaleMode = AutoScaleMode.None;

        var layout = new WorkspaceRows(this, 50, -1, 48);
        var searchBox = new RoundedPanel { BackColor = Ui.Surface, Dock = DockStyle.Fill,
            Margin = Padding.Empty, Corner = 9 };
        searchBox.Controls.Add(search);
        var filterInput = new Panel { Dock = DockStyle.Fill };
        filterInput.Controls.Add(searchBox);
        filterInput.Controls.Add(collectionPicker);
        available.Text = "仅看异画";
        available.Anchor = AnchorStyles.Left;
        var filters = Ui.WorkspaceBar(0, filterInput, collection, available, newCollection);
        layout.Controls.Add(filters, 0, 0);

        var columns = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 1, ColumnCount = 2, Margin = Padding.Empty };
        columns.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 46));
        columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 54));
        var list = new WorkspaceRows(this, 0, -1);
        count.ForeColor = Ui.Muted;
        count.Margin = new(3, 0, 3, 0);
        list.Controls.Add(count, 0, 0);
        count.TextChanged += (_, _) => list.SetHeight(0, count.Text.Length == 0 ? 0 : 26);
        list.SetHeight(0, 26);
        list.Controls.Add(results, 0, 1);
        var listCard = new RoundedPanel { BackColor = Ui.Surface, Dock = DockStyle.Fill,
            Padding = new(11), Margin = Padding.Empty };
        listCard.Controls.Add(list);
        columns.Controls.Add(listCard, 0, 0);
        var detail = new WorkspaceRows(this, 30, -1, 38, 43);
        title.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        detail.Controls.Add(title, 0, 0);
        var previewArea = new Panel { Dock = DockStyle.Fill, BackColor = Ui.Background };
        previewArea.Controls.Add(preview);
        previewArea.Controls.Add(previewStatus);
        previewStatus.BringToFront();
        detail.Controls.Add(previewArea, 0, 1);
        detail.Controls.Add(options, 0, 2);
        var choices = Ui.Row(addToCollection, saveChoice, removeChoice);
        choices.AutoSize = false;
        detail.Controls.Add(choices, 0, 3);
        var detailCard = new RoundedPanel { BackColor = Ui.Surface, Dock = DockStyle.Fill,
            Margin = Padding.Empty };
        detailCard.Controls.Add(detail);
        columns.Controls.Add(detailCard, 1, 0);
        void FitCardDetails()
        {
            var hasCard = title.Text.Length > 0;
            detailCard.Visible = hasCard;
            columns.ColumnStyles[0].Width = hasCard ? 46 : 100;
            columns.ColumnStyles[1].Width = hasCard ? 54 : 0;
        }
        title.TextChanged += (_, _) => FitCardDetails();
        FitCardDetails();
        layout.Controls.Add(columns, 0, 1);
        notice.ForeColor = Ui.Muted;
        retry.Visible = false;
        var actions = Ui.WorkspaceBar(0, notice, all, restore, apply, retry);
        layout.Controls.Add(actions, 0, 2);
        Controls.Add(layout);
        Ui.AtDeviceDpi(this, dpi =>
        {
            int Dip(int value) => Ui.Dip(value, dpi);
            layout.Padding = new Padding(Dip(16), Dip(14), Dip(16), Dip(6));
            filters.Margin = new Padding(0, 0, 0, Dip(9));
            filterInput.Margin = new Padding(0, Dip(3), Dip(6), Dip(3));
            searchBox.Padding = new Padding(Dip(10), Dip(7), Dip(10), 0);
            listCard.Padding = detailCard.Padding = new Padding(Dip(9));
            detailCard.Margin = new Padding(Dip(9), 0, 0, 0);
            previewArea.Margin = new Padding(Dip(3), Dip(3), Dip(3), Dip(5));
            actions.Padding = new Padding(0, Dip(5), 0, 0);
        });

        Collection[] filtersBySeries =
        {
            new("全部卡片", ""), new("闪刀姬", "闪刀"), new("烙印", "烙印"), new("黑魔导", "黑魔导")
        };
        collection.SetItems(filtersBySeries, filtersBySeries[0]);
        notice.TextChanged += (_, _) => tips.SetToolTip(notice, notice.Text);
        tips.SetToolTip(all, "同时处理所有已绑定的独立缓存。快速共享账号会随主号一起更新。");
        results.PaintCard = DrawCard;
        results.RequestThumbnails = cards => thumbnails.Request(cards.Select(engine.ThumbnailPath).OfType<string>(), ScalePixels(40));
        searchDelay.Tick += (_, _) => Filter();
        search.TextChanged += (_, _) =>
        {
            searchDelay.Stop();
            searchDelay.Start();
            UpdateButtons();
        };
        search.KeyDown += (_, args) =>
        {
            if (args.KeyCode == Keys.Escape && search.TextLength > 0)
            {
                search.Clear();
                Filter();
            }
            else if (args.KeyCode is Keys.Enter or Keys.Down)
            {
                if (searchDelay.Enabled) Filter();
                if (results.Items.Count > 0) results.Focus();
            }
            else return;
            args.SuppressKeyPress = true;
        };
        collection.SelectedIndexChanged += (_, _) => Filter();
        available.CheckedChanged += (_, _) => Filter();
        results.SelectedIndexChanged += (_, _) => ShowCard();
        options.SelectedIndexChanged += (_, _) =>
        {
            tips.SetToolTip(options, options.SelectedItem is Option { Variant: { } variant }
                ? $"{options.Text} · MDPro3 编号 {variant.Id}" : options.Text);
            ShowPreview();
        };
        all.CheckedChanged += (_, _) => UpdateButtons();
        apply.Click += async (_, _) => await EditAsync(restoreOriginal: false);
        restore.Click += async (_, _) => await EditAsync(restoreOriginal: true);
        retry.Click += async (_, _) => await LoadAsync();
        Load += async (_, _) => await LoadAsync();
        InitializeCollections();
        UpdateButtons();
    }

    private async Task LoadAsync()
    {
        SetBusy(true);
        retry.Visible = false;
        notice.Text = "";
        UpdateButtons();
        try
        {
            entries = await Task.Run(() => engine.LoadCards(source).Select(card => new CardSearchEntry(card)).ToArray());
            byCid = entries.Where(entry => entry.Card.Cid.HasValue).ToDictionary(entry => entry.Card.Cid!.Value, entry => entry.Card);
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
            ShowTargetNotice();
            Filter();
        }
        catch (Exception error)
        {
            count.Text = "卡库读取失败";
            notice.Text = error.Message;
            retry.Visible = true;
        }
        finally { SetBusy(false); UpdateButtons(); }
    }

    private void Filter()
    {
        searchDelay.Stop();
        if (entries.Length == 0) return;
        if (inCollections)
        {
            var cards = CurrentCollectionCards();
            count.Text = cards.Length == 0 ? "在卡片搜索里加入异画" : "";
            ShowResults(cards);
            return;
        }
        var query = CardSearchEntry.Normalize(search.Text);
        var term = CardSearchEntry.Normalize((collection.SelectedItem as Collection)?.Term ?? "");
        if (query.Length == 0 && term.Length == 0 && !available.Checked)
        {
            count.Text = "输入卡名或编号";
            ShowResults([]);
            return;
        }
        var matches = entries.Where(entry =>
            (!available.Checked || entry.Card.Replaceable) &&
            (term.Length == 0 || entry.Series.Any(series => series.Contains(term, StringComparison.Ordinal)) ||
                entry.Names.Any(name => name.Contains(term, StringComparison.Ordinal))))
            .Select(entry => (entry.Card, entry.Rank(query))).Where(pair => pair.Item2 >= 0)
            .OrderBy(pair => pair.Item2).ThenByDescending(pair => pair.Card.Replaceable).ToArray();
        count.Text = matches.Length > 200 ? "显示前 200 张，可缩小搜索范围" : matches.Length == 0 ? "没有匹配的卡片" : "";
        ShowResults(matches.Take(200).Select(pair => pair.Card).ToArray());
    }

    private void ShowResults(Card[] cards)
    {
        results.SetItems(cards);
        ShowCard();
    }

    private void ShowCard(int? preferredVariant = null)
    {
        var card = results.SelectedItem as Card;
        title.Text = card?.Name ?? "";
        if (card is not null)
        {
            var applied = AppliedVariant(card);
            var saved = inCollections && card.Cid is int cid ? SelectedCollection?.Choices.GetValueOrDefault(cid) : null;
            Option[] variants = [new Option("原卡图", null), .. card.Variants.Select((variant, index) => new Option(
                $"{(variant.OverFrame is null ? "异画" : "超框异画")} {index + 1}" +
                (!variant.CanApply ? "  ·  缺少超框登记" : variant.Id == applied ? "  ·  当前使用" : ""), variant))];
            var selected = variants.FirstOrDefault(option => option.Variant?.Id == (preferredVariant ?? saved ?? applied));
            if (preferredVariant is null && saved is not null && selected is not { Variant.CanApply: true })
            {
                selected = new Option("合集所选异画不可用", null);
                variants = [selected, .. variants];
            }
            options.SetItems(variants, selected ?? variants[0]);
        }
        else options.SetItems([]);
        tips.SetToolTip(title, card?.ProName is string alias && alias != title.Text ? $"{title.Text}\nMDPro3 · {alias}" : title.Text);
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
        var card = results.SelectedItem;
        var variant = (options.SelectedItem as Option)?.Variant;
        string? file = null;
        try
        {
            file = variant is not null ? engine.ArtworkPath(variant) : card is not null ? engine.OriginalPath(card) : null;
        }
        catch (InvalidDataException) { }
        if (!string.Equals(previewPath, file, StringComparison.OrdinalIgnoreCase))
        {
            previewPath = file;
            var previous = preview.Image;
            preview.Image = null;
            previous?.Dispose();
            previewStatus.Visible = file is null && card is not null;
            if (file is not null && !loadingPreview) _ = LoadPreviewAsync();
        }
        else if (file is null) previewStatus.Visible = card is not null;
        UpdateButtons();
    }

    private async Task LoadPreviewAsync()
    {
        loadingPreview = true;
        try
        {
            while (!IsDisposed && previewPath is string requested)
            {
                var image = await Task.Run(() => CardThumbnails.Read(requested, 1400));
                if (IsDisposed || requested != previewPath) { image?.Dispose(); continue; }
                preview.Image = image;
                previewStatus.Visible = image is null;
                return;
            }
        }
        finally { loadingPreview = false; }
    }

    private void UpdateButtons()
    {
        var card = results.SelectedItem as Card;
        var variant = (options.SelectedItem as Option)?.Variant;
        var canChoose = !busy && !searchDelay.Enabled && card is { Replaceable: true } && variant is { CanApply: true };
        var hasTarget = all.Checked ? targets.Length > 0 : target is not null;
        search.Enabled = collection.Enabled = available.Enabled = results.Enabled = !busy;
        options.Enabled = !busy && options.Items.Count > 0;
        all.Enabled = !busy && targets.Length > 0;
        newCollection.Enabled = !busy && entries.Length > 0 && collectionsError is null;
        collectionPicker.Enabled = !busy;
        addToCollection.Enabled = canChoose && collectionsError is null;
        saveChoice.Enabled = canChoose && SelectedCollection is { } set && card?.Cid is int cid &&
            set.Choices.GetValueOrDefault(cid) != variant?.Id;
        removeChoice.Enabled = !busy && SelectedCollection is not null && card?.Cid is not null;
        var canEdit = !busy && !searchDelay.Enabled && hasTarget;
        if (inCollections)
        {
            var canRestore = CollectionEdits(restore: true) is { Length: > 0 };
            restore.Enabled = canEdit && canRestore;
            apply.Enabled = canEdit && canRestore && CollectionEdits(restore: false) is { Length: > 0 };
        }
        else
        {
            apply.Enabled = canEdit && canChoose;
            restore.Enabled = canEdit && card?.Path is not null;
        }
    }

    private async Task EditAsync(bool restoreOriginal)
    {
        if (busy || searchDelay.Enabled) return;
        var previousVariant = (options.SelectedItem as Option)?.Variant?.Id;
        ArtworkChoice[]? edits;
        if (inCollections) edits = CollectionEdits(restoreOriginal);
        else
        {
            if (results.SelectedItem is not Card { Path: not null } card) return;
            var choice = restoreOriginal ? null : (options.SelectedItem as Option)?.Variant;
            if (!restoreOriginal && choice is not { CanApply: true }) return;
            edits = [new(card, choice)];
        }
        if (edits is not { Length: > 0 }) return;
        var selected = all.Checked ? targets : target is null ? [] : [target];
        if (selected.Length == 0) return;
        SetBusy(true);
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
                        ArtworkFiles.ApplySelection(cache, edits, engine, EnsureGameClosed);
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
            SetBusy(false);
            ShowCard(restoreOriginal ? null : previousVariant);
        }
    }

    private void SetBusy(bool value)
    {
        busy = value;
        BusyChanged?.Invoke();
    }

    private int ScalePixels(int value) => (value * DeviceDpi + 48) / 96;

    private void DrawCard(Graphics graphics, Rectangle bounds, Card card, bool selected)
    {
        if (selected) Ui.RoundedFill(graphics, Rectangle.Inflate(bounds, -1, -1), ScalePixels(7), Ui.Highlight);
        var size = ScalePixels(40);
        var tile = new Rectangle(bounds.X + ScalePixels(8), bounds.Y + (bounds.Height - size) / 2, size, size);
        if (engine.ThumbnailPath(card) is string file && thumbnails.Get(file) is { } thumbnail)
            graphics.DrawImageUnscaled(thumbnail, tile.X + (tile.Width - thumbnail.Width) / 2, tile.Y + (tile.Height - thumbnail.Height) / 2);
        else Ui.RoundedFill(graphics, tile, ScalePixels(4), Ui.Background);
        var left = ScalePixels(56);
        TextRenderer.DrawText(graphics, card.Name, Font, new Rectangle(bounds.X + left, bounds.Y,
            Math.Max(0, bounds.Width - left - ScalePixels(4)), bounds.Height), Ui.Text,
            TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            searchDelay.Dispose();
            thumbnails.Dispose();
            preview.Image?.Dispose();
            tips.Dispose();
        }
        base.Dispose(disposing);
    }

    private static void EnsureGameClosed()
    {
        if (SteamSession.GameRunning()) throw new InvalidOperationException("请先退出 Master Duel，再修改卡图。");
    }
}

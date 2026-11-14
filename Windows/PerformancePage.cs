namespace MDSwitcher;

internal sealed class PerformancePage : UserControl
{
    private readonly CardEngine engine;
    private readonly string source;
    private readonly string? cache;
    private readonly TextBox search = new() { PlaceholderText = "搜索卡名或画款编号", Dock = DockStyle.Fill };
    private readonly ChoiceDropDown<string> category = new("演出分类", item => item) { DropDown = true, Dock = DockStyle.Fill };
    private readonly PerformanceList rows = new() { Dock = DockStyle.Fill, AccessibleName = "卡片演出列表" };
    private readonly Label status = Ui.Field("", 24);
    private readonly Button apply = Ui.Button("应用到所选账号", primary: true);
    private readonly Button restore = Ui.Button("恢复原演出");
    private readonly Button retry = Ui.Button("重试");
    private readonly Dictionary<(int Card, bool Activation), Performance> selected = [];
    private readonly Dictionary<int, int?> artwork = [];
    private PerformanceRow[] options = [];
    private bool loaded;
    public bool Busy { get; private set; }
    public event Action? BusyChanged;

    public PerformancePage(CardEngine engine, string source, string? cache, string? account)
    {
        this.engine = engine;
        this.source = source;
        this.cache = cache;
        Dock = DockStyle.Fill;
        var layout = new WorkspaceRows(this, 34, 43, -1, 45);
        layout.Padding = new(16, 14, 16, 8);
        layout.Controls.Add(Ui.Heading(account is null ? "卡片演出" : $"卡片演出   ·   {account}", Font, 12), 0, 0);
        layout.Controls.Add(Ui.WorkspaceBar(0, search, category), 0, 1);
        layout.Controls.Add(rows, 0, 2);
        layout.Controls.Add(Ui.WorkspaceBar(0, status, retry, restore, apply), 0, 3);
        Controls.Add(layout);

        category.SetItems(["召唤演出替换", "发动演出替换", "新增召唤演出"], "召唤演出替换");
        category.SelectedIndexChanged += (_, _) => Filter();
        search.TextChanged += (_, _) => Filter();
        rows.ItemCheck += (_, args) =>
        {
            if (rows.Updating || rows.Items[args.Index] is not PerformanceRow row) return;
            var option = row.Option;
            if (selected.GetValueOrDefault(option.Slot) == option && args.NewValue == CheckState.Unchecked)
                selected.Remove(option.Slot);
            else if (cache is not null && MatchesArtwork(option) && args.NewValue == CheckState.Checked)
                selected[option.Slot] = option;
            else args.NewValue = args.CurrentValue;
            rows.BeginInvoke(Filter);
        };
        apply.Click += async (_, _) => await ApplyAsync(selected.Values.ToArray());
        restore.Click += async (_, _) => await ApplyAsync([]);
        retry.Click += async (_, _) => await LoadAsync();
        UpdateButtons();
    }

    public Task StartAsync() => LoadAsync();

    private async Task LoadAsync()
    {
        if (Busy) return;
        SetBusy(true);
        status.Text = "正在读取本机演出…";
        try
        {
            var result = await Task.Run(() =>
            {
                var cards = engine.LoadCards(source);
                if (cache is null) return (cards, (Performance[])[], new Dictionary<int, int?>());
                var index = GameResources.ReadIndex(cache).Items.ToDictionary(entry => entry.Name);
                var applied = ArtworkFiles.AppliedPerformances(cache);
                var installed = cards.Where(card => card is { Cid: not null, Path: not null, Performances.Length: > 0 } &&
                    index.ContainsKey(card.Path)).ToDictionary(card => card.Cid!.Value,
                    card => ArtworkFiles.AppliedVariant(cache, index[card.Path!]));
                return (cards, applied, installed);
            });
            if (IsDisposed) return;
            var (catalog, applied, installed) = result;
            artwork.Clear();
            foreach (var (cid, id) in installed) artwork[cid] = id;
            var byId = catalog.Where(card => card.Cid.HasValue).ToDictionary(card => card.Cid!.Value);
            var available = catalog.SelectMany(card => card.Performances ?? []).ToArray();
            selected.Clear();
            foreach (var option in applied)
            {
                var choices = byId.GetValueOrDefault(option.Cid)?.Performances ?? [];
                var print = artwork.GetValueOrDefault(option.Cid);
                var exact = choices.FirstOrDefault(choice => choice.Slot == option.Slot &&
                    choice.ArtworkID == (print ?? option.ArtworkID));
                if (exact is not null) selected[exact.Slot] = exact;
                else if (print is null || print == option.ArtworkID) selected[option.Slot] = option;
            }
            options = available.Union(selected.Values).Select(option =>
            {
                var card = byId.GetValueOrDefault(option.Cid);
                var variant = card is null ? -1 : Array.FindIndex(card.Variants, print => print.Id == option.ArtworkID);
                var label = card?.OriginalArtworkID == option.ArtworkID ? "原卡图"
                    : variant >= 0 ? $"异画 {variant + 1}" : $"画款 {option.ArtworkID}";
                return new PerformanceRow(option, card?.ProName, label, MatchesArtwork(option));
            }).OrderBy(row => row.Option.Name, StringComparer.CurrentCulture)
              .ThenBy(row => row.Option.ArtworkID).ToArray();
            loaded = true;
            status.Text = cache is null ? "请选中绑定了独立缓存的账号。" : "";
            Filter();
        }
        catch (Exception error) { if (!IsDisposed) status.Text = error.Message; }
        finally { if (!IsDisposed) SetBusy(false); }
    }

    private bool MatchesArtwork(Performance option) =>
        artwork.GetValueOrDefault(option.Cid) is not int id || id == option.ArtworkID;

    private void Filter()
    {
        var query = CardSearchEntry.Normalize(search.Text);
        var visible = options.Where(row => row.Option.Category == category.SelectedItem &&
            (query.Length == 0 || CardSearchEntry.Normalize(row.Option.Name).Contains(query, StringComparison.Ordinal) ||
             CardSearchEntry.Normalize(row.OtherName ?? "").Contains(query, StringComparison.Ordinal) ||
             row.Option.ArtworkID.ToString().StartsWith(query, StringComparison.Ordinal)));
        rows.ShowRows(visible, selected);
    }

    private async Task ApplyAsync(Performance[] choices)
    {
        if (Busy || cache is not string target) return;
        SetBusy(true);
        status.Text = "正在应用卡片演出…";
        try
        {
            await Task.Run(() => ArtworkFiles.ApplySelection(target, [], engine, () =>
            {
                if (SteamSession.GameRunning()) throw new IOException("请先退出 Master Duel。");
            }, choices));
            selected.Clear();
            foreach (var option in choices) selected.Add(option.Slot, option);
            Filter();
            status.Text = choices.Length == 0 ? "已恢复原演出。" : $"已应用 {choices.Length} 项演出。";
        }
        catch (Exception error) { status.Text = error.Message; }
        finally { SetBusy(false); }
    }

    private void SetBusy(bool value)
    {
        Busy = value;
        UpdateButtons();
        BusyChanged?.Invoke();
    }

    private void UpdateButtons()
    {
        search.Enabled = category.Enabled = rows.Enabled = !Busy && loaded;
        apply.Enabled = !Busy && loaded && cache is not null;
        restore.Enabled = !Busy && cache is not null;
        retry.Visible = !Busy && !loaded;
    }

    private sealed record PerformanceRow(Performance Option, string? OtherName, string ArtworkLabel, bool Available)
    {
        public override string ToString() => $"{Option.Name}   ·   {ArtworkLabel}{(Available ? "" : "   ·   与已应用卡图不符")}";
    }

    private sealed class PerformanceList : CheckedListBox
    {
        public bool Updating { get; private set; }

        public PerformanceList()
        {
            CheckOnClick = true;
            BorderStyle = BorderStyle.None;
            IntegralHeight = false;
            BackColor = Ui.Surface;
            ForeColor = Ui.Text;
        }

        public void ShowRows(IEnumerable<PerformanceRow> items,
            IReadOnlyDictionary<(int Card, bool Activation), Performance> choices)
        {
            Updating = true;
            BeginUpdate();
            var top = TopIndex;
            try
            {
                Items.Clear();
                foreach (var item in items) Items.Add(item, choices.GetValueOrDefault(item.Option.Slot) == item.Option);
                if (Items.Count > 0) TopIndex = Math.Clamp(top, 0, Items.Count - 1);
            }
            finally { EndUpdate(); Updating = false; }
        }
    }
}

namespace MDSwitcher;

internal sealed partial class ArtworkPage
{
    private readonly string collectionsFile;
    private ArtworkCollection[] collections = [];
    private Dictionary<int, Card> byCid = [];
    private string? collectionsError;
    private bool inCollections;
    private readonly ChoiceDropDown<ArtworkCollection> collectionPicker = new("选择合集", item => item.Name)
        { Dock = DockStyle.Fill, DropDown = true, AccessibleName = "异画合集" };
    private readonly Button newCollection = Ui.Button("新建合集");
    private readonly Button addToCollection = Ui.Button("加入合集");
    private readonly Button saveChoice = Ui.Button("保存选择");
    private readonly Button removeChoice = Ui.Button("移出");

    private ArtworkCollection? SelectedCollection => collectionPicker.SelectedItem as ArtworkCollection;

    private void InitializeCollections()
    {
        try { collections = ArtworkCollection.Load(collectionsFile); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or System.Text.Json.JsonException)
        {
            collectionsError = $"异画合集读取失败。{error.Message}";
        }
        collectionPicker.SetItems(collections, collections.FirstOrDefault());
        collectionPicker.SelectedIndexChanged += (_, _) => { if (inCollections) Filter(); };
        newCollection.Click += (_, _) => EditCollections(() => CreateCollection());
        addToCollection.Click += (_, _) => ShowCollectionMenu();
        saveChoice.Click += (_, _) => EditCollections(() =>
        {
            if (SelectedCollection is { } set && results.SelectedItem is Card { Cid: int cid } &&
                options.SelectedItem is Option option)
                SaveChoice(set, cid, option.Variant?.Id ?? ArtworkCollection.CardOnly);
        });
        removeChoice.Click += (_, _) => EditCollections(() =>
        {
            if (SelectedCollection is { } set && results.SelectedItem is Card { Cid: int cid })
                SaveChoice(set, cid, null);
        });
        ShowCollections(false);
    }

    internal void ShowCollections(bool show)
    {
        inCollections = show;
        search.Parent!.Visible = collection.Visible = available.Visible = addToCollection.Visible = !show;
        collectionPicker.Visible = newCollection.Visible = saveChoice.Visible = removeChoice.Visible = show;
        apply.Text = show ? "应用整套" : "应用异画";
        if (entries.Length > 0) ShowTargetNotice();
        Filter();
        UpdateButtons();
    }

    private void ShowTargetNotice()
    {
        notice.Text = inCollections && collectionsError is not null ? collectionsError
            : sharedTarget ? "共享缓存 · 单独修改前请恢复原缓存"
            : target is null ? "请先绑定游戏目录"
            : target.Name;
    }

    private Card[] CurrentCollectionCards() => SelectedCollection is { } set
        ? set.Choices.Keys.Order().Select(cid => byCid.TryGetValue(cid, out var card) ? card
            : new Card($"missing-{cid}", cid, null, $"编号 {cid}", [], [], [], null, [])).ToArray()
        : [];

    private ArtworkChoice[]? CollectionEdits(bool restore)
    {
        if (SelectedCollection is not { } set) return null;
        var edits = new List<ArtworkChoice>();
        foreach (var (cid, id) in set.Choices)
        {
            if (id == ArtworkCollection.CardOnly) continue;
            if (!byCid.TryGetValue(cid, out var card) || card.Path is null) return null;
            var variant = restore ? null : card.Variants.FirstOrDefault(variant => variant.Id == id && variant.CanApply);
            if (!restore && variant is null) return null;
            edits.Add(new ArtworkChoice(card, variant));
        }
        return edits.ToArray();
    }

    private void ShowCollectionMenu()
    {
        if (results.SelectedItem is not Card { Cid: int cid }) return;
        var chosen = (options.SelectedItem as Option)?.Variant;
        var variant = chosen is { CanApply: true } ? chosen.Id : (int?)null;
        var menu = new ChoiceMenu(addToCollection);
        foreach (var set in collections)
            menu.Add(set.Name, () => EditCollections(() => SaveChoice(set, cid,
                variant ?? set.Choices.GetValueOrDefault(cid, ArtworkCollection.CardOnly))));
        menu.Add("新建合集…", () => EditCollections(() => CreateCollection(cid, variant ?? ArtworkCollection.CardOnly)));
        menu.ShowBelow();
    }

    private void CreateCollection(int? cid = null, int? variant = null)
    {
        using var dialog = new Form
        {
            Text = "新建异画合集", ClientSize = new(380, 134), StartPosition = FormStartPosition.CenterParent,
            FormBorderStyle = FormBorderStyle.FixedDialog, ShowInTaskbar = false, MaximizeBox = false, MinimizeBox = false,
        };
        Ui.Style(dialog);
        var layout = Ui.Stack(SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        layout.Padding = new(15);
        var input = new TextBox { Dock = DockStyle.Top, MaxLength = 36, AccessibleName = "合集名称" };
        var create = Ui.Button("新建", primary: true);
        create.Enabled = false;
        create.DialogResult = DialogResult.OK;
        var cancel = Ui.Button("取消");
        cancel.DialogResult = DialogResult.Cancel;
        input.TextChanged += (_, _) => create.Enabled = input.Text.Trim().Length > 0;
        layout.Controls.Add(Ui.Label("合集名称"), 0, 0);
        layout.Controls.Add(input, 0, 1);
        layout.Controls.Add(Ui.Row(create, cancel), 0, 2);
        dialog.Controls.Add(layout);
        dialog.AcceptButton = create;
        dialog.CancelButton = cancel;
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var name = input.Text.Trim();
        if (collections.Any(set => set.Name.Equals(name, StringComparison.CurrentCultureIgnoreCase)))
            throw new InvalidOperationException("已有同名合集，请换一个名称。");
        var choices = new Dictionary<int, int>();
        if (cid is int key && variant is int id) choices.Add(key, id);
        var added = new ArtworkCollection(Guid.NewGuid().ToString("N"), name, choices);
        SaveCollections([.. collections, added], added.Id);
        notice.Text = $"已新建「{name}」{(choices.Count == 0 ? "。" : "并加入所选卡片。")}";
    }

    private void SaveChoice(ArtworkCollection set, int cid, int? variant)
    {
        var choices = new Dictionary<int, int>(set.Choices);
        if (variant is int id) choices[cid] = id;
        else choices.Remove(cid);
        var updated = set with { Choices = choices };
        SaveCollections(collections.Select(item => item.Id == set.Id ? updated : item).ToArray(), set.Id);
        notice.Text = variant is null ? $"已从「{set.Name}」移除卡片。" : $"已保存到「{set.Name}」。";
    }

    private void SaveCollections(ArtworkCollection[] updated, string selected)
    {
        ArtworkCollection.Save(collectionsFile, updated);
        collections = updated;
        collectionPicker.SetItems(collections, collections.FirstOrDefault(item => item.Id == selected));
        UpdateButtons();
    }

    private void EditCollections(Action action)
    {
        try { action(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            notice.Text = error.Message;
        }
    }
}

using System.ComponentModel;
namespace MDSwitcher;

internal sealed class ChoiceList<T> : Panel where T : class
{
    private readonly TableLayoutPanel stack = Ui.Stack();
    private readonly List<T> items = [];
    private readonly List<Tile> tiles = [];
    private readonly int rowHeight;
    private readonly Action<Graphics, Rectangle, T, bool, bool> paintItem;
    private readonly Func<T, string> itemName;
    private int selected = -1;

    public ChoiceList(int rowHeight, Action<Graphics, Rectangle, T, bool, bool> paintItem, Func<T, string> itemName)
    {
        this.rowHeight = rowHeight;
        this.paintItem = paintItem;
        this.itemName = itemName;
        Dock = DockStyle.Fill;
        AutoScroll = true;
        AccessibleRole = AccessibleRole.List;
        stack.Dock = DockStyle.Top;
        stack.AutoSize = true;
        stack.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Controls.Add(stack);
    }

    public event EventHandler? SelectedIndexChanged;
    public IReadOnlyList<T> Items => items;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal T? SelectedItem
    {
        get => selected < 0 ? null : items[selected];
        set => SelectedIndex = value is null ? -1 : items.IndexOf(value);
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal int SelectedIndex
    {
        get => selected;
        set
        {
            if (value < -1 || value >= items.Count) throw new ArgumentOutOfRangeException(nameof(value));
            if (value == selected) return;
            selected = value;
            Redraw();
            if (selected >= 0) ScrollControlIntoView(tiles[selected]);
            SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void SetItems(IEnumerable<T> values, T? choice = null)
    {
        SuspendLayout();
        stack.SuspendLayout();
        foreach (var tile in tiles) tile.Dispose();
        stack.RowStyles.Clear();
        items.Clear();
        tiles.Clear();
        items.AddRange(values);
        stack.RowCount = items.Count;
        for (int index = 0; index < items.Count; index++)
        {
            var tile = new Tile(this, index)
            {
                Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Margin = new(0, 0, Ui.Dip(2, DeviceDpi), Ui.Dip(5, DeviceDpi)), Cursor = Cursors.Hand,
                AccessibleRole = AccessibleRole.ListItem,
            };
            tiles.Add(tile);
            stack.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            stack.Controls.Add(tile, 0, index);
        }
        selected = choice is null ? -1 : items.IndexOf(choice);
        stack.ResumeLayout();
        ResumeLayout();
        Redraw();
        if (selected >= 0) ScrollControlIntoView(tiles[selected]);
        SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Redraw()
    {
        for (int index = 0; index < tiles.Count; index++)
        {
            var tile = tiles[index];
            tile.AccessibleName = itemName(items[index]);
            tile.AccessibleDescription = index == selected ? "已选中" : "";
            tile.TabStop = index == (selected < 0 ? 0 : selected);
            tile.Invalidate();
        }
    }

    private sealed class Tile(ChoiceList<T> list, int index) : Button
    {
        private bool hover;
        public override Size GetPreferredSize(Size proposedSize) => new(0, Ui.Dip(list.rowHeight, DeviceDpi));

        protected override void OnPaint(PaintEventArgs e)
        {
            using var background = new SolidBrush(Parent?.BackColor ?? Ui.Surface);
            e.Graphics.FillRectangle(background, ClientRectangle);
            var bounds = ClientRectangle;
            bounds.Inflate(-1, -1);
            list.paintItem(e.Graphics, bounds, list.items[index], list.selected == index, hover || (Focused && ShowFocusCues));
        }

        protected override void OnClick(EventArgs e) { list.SelectedIndex = index; base.OnClick(e); }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; Invalidate(); }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            var next = keyData switch { Keys.Up => index - 1, Keys.Down => index + 1, _ => -2 };
            if (next == -2) return base.ProcessCmdKey(ref msg, keyData);
            if (next >= 0 && next < list.Items.Count)
            {
                list.SelectedIndex = next;
                list.tiles[next].Focus();
            }
            return true;
        }
    }
}

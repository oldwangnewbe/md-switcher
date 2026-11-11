using System.ComponentModel;

namespace MDSwitcher;

internal sealed class ChoiceDropDown<T> : RoundedButton where T : class
{
    private readonly string emptyText;
    private readonly Func<T, string> label;
    private T[] items = [];
    private int selectedIndex = -1;

    public ChoiceDropDown(string emptyText, Func<T, string> label)
    {
        this.emptyText = emptyText;
        this.label = label;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderColor = Ui.Border;
        FlatAppearance.MouseOverBackColor = Ui.Highlight;
        BackColor = Ui.Surface;
        ForeColor = Ui.Text;
        UseVisualStyleBackColor = false;
        TextAlign = ContentAlignment.MiddleLeft;
        Cursor = Cursors.Hand;
    }

    public event EventHandler? SelectedIndexChanged;
    public IReadOnlyList<T> Items => items;

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal T? SelectedItem
    {
        get => selectedIndex < 0 ? null : items[selectedIndex];
        set => SelectedIndex = Array.IndexOf(items, value);
    }

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal int SelectedIndex
    {
        get => selectedIndex;
        set
        {
            if (value < -1 || value >= items.Length) throw new ArgumentOutOfRangeException(nameof(value));
            if (selectedIndex == value) return;
            selectedIndex = value;
            UpdateLabel();
            SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void SetItems(IEnumerable<T> values, T? selected = null)
    {
        items = values.ToArray();
        selectedIndex = Array.IndexOf(items, selected);
        UpdateLabel();
        SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
    }

    private void UpdateLabel()
    {
        Text = SelectedItem is { } item ? label(item) : emptyText;
        AccessibleDescription = Text;
    }

    protected override void OnClick(EventArgs e)
    {
        base.OnClick(e);
        if (items.Length == 0) return;
        var menu = new ChoiceMenu(this, Width);
        for (var i = 0; i < items.Length; i++)
        {
            var index = i;
            menu.Add(label(items[i]), () => SelectedIndex = index, index == selectedIndex);
        }
        menu.ShowBelow();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == (Keys.Alt | Keys.Down) || keyData == Keys.F4)
        {
            OnClick(EventArgs.Empty);
            return true;
        }
        if (items.Length > 0 && keyData is Keys.Up or Keys.Down)
        {
            SelectedIndex = Math.Clamp(selectedIndex + (keyData == Keys.Down ? 1 : -1), 0, items.Length - 1);
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}

internal sealed class ChoiceMenu : ContextMenuStrip
{
    private readonly Control anchor;
    private readonly int minWidth;

    public ChoiceMenu(Control anchor, int minWidth = 0)
    {
        this.anchor = anchor;
        this.minWidth = minWidth;
        Font = anchor.Font;
        BackColor = Ui.Surface;
        ForeColor = Ui.Text;
        ShowImageMargin = false;
        ShowCheckMargin = false;
        Padding = new Padding(Ui.Dip(4, anchor.DeviceDpi));
        Renderer = new ChoiceRenderer();
        Closed += (_, _) =>
        {
            if (anchor.IsHandleCreated) anchor.BeginInvoke(new Action(Dispose));
            else Dispose();
        };
    }

    public void Add(string text, Action action, bool selected = false)
    {
        var label = (selected ? "✓   " : "    ") + text.Replace("&", "&&");
        var item = new ToolStripMenuItem(label) { Checked = selected, Font = Font, Padding = new Padding(5, 2, 5, 2) };
        var size = item.GetPreferredSize(Size.Empty);
        item.AutoSize = false;
        item.Size = new Size(Math.Max(size.Width + Ui.Dip(30, anchor.DeviceDpi), minWidth - Padding.Horizontal),
            Math.Max(size.Height, Ui.Dip(32, anchor.DeviceDpi)));
        item.Click += (_, _) => action();
        Items.Add(item);
    }

    public void ShowBelow() => Show(anchor, new Point(0, anchor.Height + Ui.Dip(3, anchor.DeviceDpi)));

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (Width < 2 || Height < 2) return;
        using var shape = Ui.RoundedPath(ClientRectangle, Ui.Dip(8, DeviceDpi));
        Region = new Region(shape);
    }

    private sealed class ChoiceRenderer : ToolStripRenderer
    {
        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using var fill = new SolidBrush(Ui.Surface);
            e.Graphics.FillRectangle(fill, e.AffectedBounds);
        }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            var bounds = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
            using var shape = Ui.RoundedPath(bounds, Ui.Dip(8, e.ToolStrip.DeviceDpi));
            using var pen = new Pen(Ui.Border, Math.Max(1, e.Graphics.DpiX / 96));
            e.Graphics.DrawPath(pen, shape);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (e.Item.Selected || e.Item is ToolStripMenuItem { Checked: true })
                Ui.RoundedFill(e.Graphics, new Rectangle(1, 1, e.Item.Width - 2, e.Item.Height - 2),
                    Ui.Dip(6, (int)e.Graphics.DpiX), Ui.Highlight);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = e.Item is ToolStripMenuItem { Checked: true } ? Ui.Accent : Ui.Text;
            base.OnRenderItemText(e);
        }
    }
}

using System.ComponentModel;
using System.Diagnostics;

namespace MDSwitcher;

internal sealed class CardResultList : Control, IMessageFilter
{
    private readonly VScrollBar scroll = new() { Dock = DockStyle.Right, TabStop = false };
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 15 };
    private readonly Stopwatch elapsed = new();
    private Card[] items = [];
    private int selected = -1;
    private int offset;
    private double start;
    private double destination;
    private bool scrollable;

    public CardResultList()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        BackColor = Ui.Surface;
        TabStop = true;
        AccessibleName = "卡片搜索结果";
        AccessibleRole = AccessibleRole.List;
        scroll.Visible = false;
        scroll.Scroll += (_, args) => MoveTo(args.NewValue);
        Controls.Add(scroll);
        animation.Tick += (_, _) => Animate();
    }

    public event EventHandler? SelectedIndexChanged;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<Graphics, Rectangle, Card, bool>? PaintCard { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<Card[]>? RequestThumbnails { get; set; }
    public IReadOnlyList<Card> Items => items;
    private int RowHeight => Ui.Dip(46, DeviceDpi);
    private int MaxOffset => Math.Max(0, items.Length * RowHeight - Math.Max(1, ClientSize.Height));
    private int ListWidth => Math.Max(0, ClientSize.Width - (scrollable ? scroll.Width : 0));

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Card? SelectedItem
    {
        get => selected < 0 ? null : items[selected];
        set => Select(value is null ? -1 : Array.FindIndex(items, card => card.Id == value.Id));
    }

    public void SetItems(Card[] values)
    {
        if (items.AsSpan().SequenceEqual(values)) return;
        var id = SelectedItem?.Id;
        items = values;
        selected = Array.FindIndex(items, card => card.Id == id);
        if (selected < 0 && items.Length > 0) selected = 0;
        UpdateRange();
        MoveTo(0);
        if (selected >= 0) RevealSelection();
        AccessibilityNotifyClients(AccessibleEvents.Reorder, -1);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Application.AddMessageFilter(this);
        UpdateRange();
    }

    protected override void OnHandleDestroyed(EventArgs e)
    {
        Application.RemoveMessageFilter(this);
        animation.Stop();
        base.OnHandleDestroyed(e);
    }

    public bool PreFilterMessage(ref Message message)
    {
        const int mouseWheel = 0x020A;
        if (message.Msg != mouseWheel || !Visible || !Enabled || !scrollable || Form.ActiveForm != FindForm() ||
            !ClientRectangle.Contains(PointToClient(Cursor.Position))) return false;
        ScrollWheel(unchecked((short)(message.WParam.ToInt64() >> 16)));
        return true;
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (!scrollable) { base.OnMouseWheel(e); return; }
        ScrollWheel(e.Delta);
        if (e is HandledMouseEventArgs handled) handled.Handled = true;
    }

    private void ScrollWheel(int delta)
    {
        var lines = SystemInformation.MouseWheelScrollLines;
        var pixels = lines < 0 ? ClientSize.Height : lines * RowHeight;
        var next = Math.Clamp(destination - delta * (pixels / 120d), 0, MaxOffset);
        if (next == destination) return;
        start = offset;
        destination = next;
        elapsed.Restart();
        animation.Start();
    }

    private void Animate()
    {
        var progress = Math.Min(1, elapsed.Elapsed.TotalMilliseconds / 115);
        var eased = 1 - Math.Pow(1 - progress, 3);
        SetOffset((int)Math.Round(start + (destination - start) * eased));
        if (progress >= 1) animation.Stop();
    }

    private void MoveTo(int value)
    {
        animation.Stop();
        destination = Math.Clamp(value, 0, MaxOffset);
        SetOffset((int)destination);
    }

    private void SetOffset(int value)
    {
        var moved = offset != value;
        offset = value;
        if (scroll.Value != value) scroll.Value = value;
        if (moved) Invalidate();
    }

    private void UpdateRange()
    {
        scrollable = MaxOffset > 0;
        scroll.Visible = scrollable;
        scroll.Maximum = Math.Max(0, items.Length * RowHeight - 1);
        scroll.LargeChange = Math.Max(1, ClientSize.Height);
        scroll.SmallChange = RowHeight;
        MoveTo(offset);
        Invalidate();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        UpdateRange();
    }

    protected override void OnDpiChangedAfterParent(EventArgs e)
    {
        base.OnDpiChangedAfterParent(e);
        UpdateRange();
        if (selected >= 0) RevealSelection();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var first = offset / RowHeight;
        var end = Math.Min(items.Length, (offset + ClientSize.Height + RowHeight - 1) / RowHeight);
        for (var i = first; i < end; i++)
        {
            var bounds = ItemBounds(i);
            if (!bounds.IntersectsWith(e.ClipRectangle)) continue;
            PaintCard?.Invoke(e.Graphics, bounds, items[i], i == selected);
            if (i == selected && Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(bounds, -2, -2));
        }
        var prefetch = Math.Max(0, first - 2);
        RequestThumbnails?.Invoke(items[prefetch..Math.Min(items.Length, end + 2)]);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left || e.X >= ListWidth) return;
        var index = (e.Y + offset) / RowHeight;
        if (index >= items.Length) return;
        Focus();
        Select(index);
    }

    protected override bool IsInputKey(Keys keyData) => (keyData & Keys.KeyCode) is
        Keys.Up or Keys.Down or Keys.PageUp or Keys.PageDown or Keys.Home or Keys.End || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (items.Length == 0) { base.OnKeyDown(e); return; }
        var page = Math.Max(1, ClientSize.Height / RowHeight);
        var index = e.KeyCode switch
        {
            Keys.Up => selected - 1,
            Keys.Down => selected + 1,
            Keys.PageUp => selected - page,
            Keys.PageDown => selected + page,
            Keys.Home => 0,
            Keys.End => items.Length - 1,
            _ => int.MinValue,
        };
        if (index == int.MinValue) { base.OnKeyDown(e); return; }
        Select(Math.Clamp(index, 0, items.Length - 1));
        e.Handled = true;
    }

    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

    private void Select(int index)
    {
        if (selected == index) { if (selected >= 0) RevealSelection(); return; }
        var old = selected;
        selected = index;
        if (old >= 0) Invalidate(ItemBounds(old));
        if (selected >= 0)
        {
            RevealSelection();
            Invalidate(ItemBounds(selected));
            AccessibilityNotifyClients(AccessibleEvents.Selection, selected);
            if (Focused) AccessibilityNotifyClients(AccessibleEvents.Focus, selected);
        }
        SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
    }

    private void RevealSelection()
    {
        var bounds = ItemBounds(selected);
        var next = bounds.Top < 0 ? offset + bounds.Top
            : bounds.Bottom > ClientSize.Height ? offset + bounds.Bottom - ClientSize.Height : offset;
        MoveTo(next);
    }

    private Rectangle ItemBounds(int index) => new(0, index * RowHeight - offset, ListWidth, RowHeight);

    protected override AccessibleObject CreateAccessibilityInstance() => new ResultAccessibility(this);

    private sealed class ResultAccessibility(CardResultList list) : ControlAccessibleObject(list)
    {
        public override int GetChildCount() => list.items.Length;
        public override AccessibleObject? GetChild(int index) => index >= 0 && index < list.items.Length
            ? new ItemAccessibility(list, this, index) : null;
        public override AccessibleObject? GetFocused() => list.Focused ? GetChild(list.selected) : null;
        public override AccessibleObject? GetSelected() => GetChild(list.selected);
        public override AccessibleObject? HitTest(int x, int y)
        {
            var point = list.PointToClient(new Point(x, y));
            return list.ClientRectangle.Contains(point) && point.X < list.ListWidth
                ? GetChild((point.Y + list.offset) / list.RowHeight) ?? this : base.HitTest(x, y);
        }
    }

    private sealed class ItemAccessibility(CardResultList list, AccessibleObject parent, int index) : AccessibleObject
    {
        public override string? Name { get => index < list.items.Length ? list.items[index].Name : null; set { } }
        public override AccessibleObject Parent => parent;
        public override AccessibleRole Role => AccessibleRole.ListItem;
        private Rectangle VisibleBounds => Rectangle.Intersect(list.ClientRectangle, list.ItemBounds(index));
        public override Rectangle Bounds => VisibleBounds.Height <= 0 ? Rectangle.Empty : list.RectangleToScreen(VisibleBounds);
        public override AccessibleStates State => AccessibleStates.Selectable | AccessibleStates.Focusable |
            (VisibleBounds.Height <= 0 ? AccessibleStates.Offscreen : 0) |
            (list.selected == index ? AccessibleStates.Selected | (list.Focused ? AccessibleStates.Focused : 0) : 0);
        public override string DefaultAction => "选择卡片";
        public override void DoDefaultAction()
        {
            if (index >= list.items.Length) return;
            list.Focus();
            list.Select(index);
        }
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing) animation.Dispose();
    }
}

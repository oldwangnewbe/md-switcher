using System.ComponentModel;
using System.Drawing.Drawing2D;

namespace MDSwitcher;

internal static class Ui
{
    public static readonly Color Background = Color.FromArgb(245, 246, 250);
    public static readonly Color Surface = Color.White;
    public static readonly Color Text = Color.FromArgb(23, 31, 53);
    public static readonly Color Muted = Color.FromArgb(82, 94, 119);
    public static readonly Color Accent = Color.FromArgb(105, 76, 197);
    public static readonly Color Highlight = Color.FromArgb(240, 235, 251);
    public static readonly Color Border = Color.FromArgb(225, 228, 238);
    public static readonly Color Rail = Color.White;
    public static readonly Color RailSelected = Highlight;
    public static readonly Color RailText = Muted;
    public static readonly Color Green = Color.FromArgb(23, 116, 90);
    public static readonly Color GreenTint = Color.FromArgb(231, 247, 239);

    public static void Style(Form form)
    {
        form.Font = new Font("Microsoft YaHei UI", 10);
        form.BackColor = Background;
        form.ForeColor = Text;
        form.AutoScaleMode = AutoScaleMode.Dpi;
        form.AutoScaleDimensions = new SizeF(96, 96);
    }

    public static Button Button(string text, bool primary = false, bool dropDown = false)
    {
        var button = new RoundedButton
        {
            Text = text, AutoSize = true, FlatStyle = FlatStyle.Flat,
            DropDown = dropDown,
            BackColor = primary ? Accent : Surface, ForeColor = primary ? Color.White : Text,
            UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderColor = primary ? Accent : Border;
        button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(89, 61, 178) : Highlight;
        button.Cursor = Cursors.Hand;
        return button;
    }

    public static Label Heading(string text, Font font, float size) =>
        new() { Text = text, AutoSize = true, ForeColor = Text, Font = new Font(font.FontFamily, size, FontStyle.Bold) };

    public static Label Field(string text, int height = 24) => new SingleLineLabel(height)
    {
        Text = text, Dock = DockStyle.Fill, Height = height,
        ForeColor = Text, TextAlign = ContentAlignment.MiddleLeft, UseMnemonic = false,
    };

    public static int Dip(int pixels, int dpi) => (pixels * dpi + 48) / 96;

    public static void RoundedFill(Graphics graphics, Rectangle bounds, int radius, Color color, Color? border = null)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        using var brush = new SolidBrush(color);
        using var path = RoundedPath(bounds, radius);
        var previous = graphics.SmoothingMode;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.FillPath(brush, path);
        if (border is Color outline)
        {
            using var pen = new Pen(outline, Math.Max(1, graphics.DpiX / 96));
            graphics.DrawPath(pen, path);
        }
        graphics.SmoothingMode = previous;
    }

    public static GraphicsPath RoundedPath(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        var diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        if (diameter <= 1) { path.AddRectangle(bounds); return path; }
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static Label Label(string text, bool muted = false) =>
        new() { Text = text, AutoSize = true, ForeColor = muted ? Muted : Text };

    public static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = false, Margin = Padding.Empty };
        row.Controls.AddRange(controls);
        return row;
    }

    public static TableLayoutPanel Stack(params SizeType[] rows)
    {
        var table = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = rows.Length, Margin = Padding.Empty };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var row in rows) table.RowStyles.Add(new RowStyle(row, row == SizeType.Percent ? 100 : 0));
        return table;
    }

    public static TableLayoutPanel WorkspaceBar(int fillColumn, params Control[] controls)
    {
        var bar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = controls.Length, RowCount = 1,
            Margin = Padding.Empty, GrowStyle = TableLayoutPanelGrowStyle.FixedSize };
        bar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        for (var i = 0; i < controls.Length; i++)
        {
            bar.ColumnStyles.Add(i == fillColumn ? new ColumnStyle(SizeType.Percent, 100) : new ColumnStyle(SizeType.AutoSize));
            if (i != fillColumn && controls[i] is Button) controls[i].Anchor = AnchorStyles.Left;
            bar.Controls.Add(controls[i], i, 0);
        }
        return bar;
    }

    public static void AtDeviceDpi(Control owner, Action<int> apply)
    {
        void Update() => apply(owner.DeviceDpi);
        owner.HandleCreated += (_, _) => Update();
        owner.DpiChangedAfterParent += (_, _) => Update();
        Update();
    }
}

// A workspace gives its spare height to the card content, independent of the preferred sizes of nested controls.
internal sealed class WorkspaceRows : TableLayoutPanel
{
    private readonly Control owner;
    private readonly int[] heights;

    public WorkspaceRows(Control owner, params int[] heights)
    {
        this.owner = owner;
        this.heights = heights;
        Dock = DockStyle.Fill;
        Margin = Padding.Empty;
        RowCount = heights.Length;
        ColumnCount = 1;
        GrowStyle = TableLayoutPanelGrowStyle.FixedSize;
        ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var height in heights)
            RowStyles.Add(height < 0 ? new RowStyle(SizeType.Percent, 100) : new RowStyle(SizeType.Absolute));
        Ui.AtDeviceDpi(owner, dpi =>
        {
            SuspendLayout();
            for (var row = 0; row < heights.Length; row++)
                if (heights[row] >= 0) RowStyles[row].Height = Ui.Dip(heights[row], dpi);
            ResumeLayout();
        });
    }

    public void SetHeight(int row, int logicalHeight)
    {
        if (heights[row] == logicalHeight) return;
        heights[row] = logicalHeight;
        RowStyles[row].Height = Ui.Dip(logicalHeight, owner.DeviceDpi);
    }
}

internal sealed class SingleLineLabel(int height) : Label
{
    public override Size GetPreferredSize(Size proposedSize)
    {
        var size = TextRenderer.MeasureText(Text, Font);
        return new(size.Width, Math.Max(Font.Height, Ui.Dip(height, DeviceDpi)));
    }

    protected override void OnPaint(PaintEventArgs e) => TextRenderer.DrawText(e.Graphics, Text, Font,
        ClientRectangle, ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine |
        TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | (TextAlign == ContentAlignment.MiddleRight ? TextFormatFlags.Right : 0));
}

internal class RoundedPanel : Panel
{
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Color? Outline { get; init; } = Ui.Border;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal int Corner { get; init; } = 15;

    public RoundedPanel()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        using var background = new SolidBrush(Parent?.BackColor ?? Ui.Background);
        e.Graphics.FillRectangle(background, ClientRectangle);
        var box = ClientRectangle;
        box.Inflate(-1, -1);
        Ui.RoundedFill(e.Graphics, box, Ui.Dip(Corner, DeviceDpi), BackColor, Outline);
    }
}

internal class RoundedButton : Button
{
    private bool hover;
    private bool pressed;
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal int NavIcon { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool DropDown { get; init; }

    public override Size GetPreferredSize(Size proposedSize)
    {
        var text = TextRenderer.MeasureText(Text, Font, new Size(int.MaxValue, int.MaxValue),
            TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix).Width;
        return new(Math.Max(MinimumSize.Width, text + Ui.Dip(DropDown ? 44 : 24, DeviceDpi)),
            Math.Max(MinimumSize.Height, Ui.Dip(36, DeviceDpi)));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var graphics = e.Graphics;
        using var background = new SolidBrush(Parent?.BackColor ?? Ui.Surface);
        graphics.FillRectangle(background, ClientRectangle);
        var face = ClientRectangle;
        face.Inflate(-1, -1);
        var fill = !Enabled && BackColor == Ui.Accent ? Ui.Highlight
            : hover && Enabled ? FlatAppearance.MouseOverBackColor : BackColor;
        if (pressed && Enabled) fill = ControlPaint.Dark(fill, 0.05f);
        var outline = Focused && ShowFocusCues ? Ui.Accent
            : FlatAppearance.BorderSize != 0 ? FlatAppearance.BorderColor : (Color?)null;
        Ui.RoundedFill(graphics, face, Ui.Dip(8, DeviceDpi), fill, outline);
        face.Inflate(-Ui.Dip(10, DeviceDpi), 0);
        if (DropDown)
        {
            var unit = DeviceDpi / 96f;
            var x = face.Right - 5 * unit;
            var y = face.Top + face.Height / 2f;
            using var pen = new Pen(Enabled ? Ui.Muted : SystemColors.GrayText, 1.5f * unit)
                { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            graphics.DrawLines(pen, [new PointF(x - 4 * unit, y - 2 * unit), new(x, y + 2 * unit), new(x + 4 * unit, y - 2 * unit)]);
            face.Width -= Ui.Dip(19, DeviceDpi);
        }
        if (NavIcon != 0)
        {
            var unit = DeviceDpi / 96f;
            var state = graphics.Save();
            graphics.TranslateTransform(face.X + 2 * unit, face.Top + (face.Height - 16 * unit) / 2);
            graphics.ScaleTransform(unit, unit);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(Enabled ? ForeColor : Ui.Muted, 1.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            if (NavIcon == 1)
            {
                graphics.DrawEllipse(pen, 5, 1, 6, 6);
                graphics.DrawArc(pen, 1, 8, 14, 12, 197, 145);
            }
            else if (NavIcon == 2)
            {
                graphics.DrawRectangle(pen, 5, 1, 9, 12);
                graphics.DrawLines(pen, [new Point(2, 4), new Point(2, 15), new Point(11, 15)]);
            }
            else if (NavIcon == 4)
            {
                graphics.DrawRectangle(pen, 2, 6, 12, 8);
                graphics.DrawLine(pen, 2, 3, 14, 3);
                graphics.DrawLine(pen, 6, 10, 10, 10);
            }
            else if (NavIcon == 5)
            {
                graphics.DrawPolygon(pen, [new Point(8, 1), new(9, 6), new(14, 8), new(9, 9),
                    new(8, 15), new(6, 9), new(1, 8), new(6, 6)]);
            }
            else if (NavIcon == 6)
            {
                graphics.DrawRectangle(pen, 1, 3, 14, 10);
                graphics.DrawPolygon(pen, [new Point(6, 5), new(11, 8), new(6, 11)]);
            }
            else
            {
                graphics.DrawLine(pen, 1, 4, 15, 4);
                graphics.DrawLine(pen, 1, 11, 15, 11);
                graphics.DrawLine(pen, 5, 2, 5, 6);
                graphics.DrawLine(pen, 11, 9, 11, 13);
            }
            graphics.Restore(state);
            var offset = Ui.Dip(24, DeviceDpi);
            face.X += offset;
            face.Width -= offset;
        }
        var align = TextAlign == ContentAlignment.MiddleLeft ? TextFormatFlags.Left : TextFormatFlags.HorizontalCenter;
        TextRenderer.DrawText(graphics, Text, Font, face, Enabled ? ForeColor : Ui.Muted,
            align | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = pressed = false; Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); pressed = true; Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); pressed = false; Invalidate(); }
}

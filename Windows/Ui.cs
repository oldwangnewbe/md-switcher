namespace MDSwitcher;

internal static class Ui
{
    public static readonly Color Background = Color.FromArgb(244, 247, 251);
    public static readonly Color Surface = Color.White;
    public static readonly Color Text = Color.FromArgb(27, 39, 58);
    public static readonly Color Muted = Color.FromArgb(80, 98, 121);
    public static readonly Color Accent = Color.FromArgb(33, 90, 186);
    public static readonly Color Highlight = Color.FromArgb(227, 239, 255);
    public static readonly Color Border = Color.FromArgb(206, 217, 230);

    public static void Style(Form form)
    {
        form.Font = new Font("Microsoft YaHei UI", 10);
        form.BackColor = Background;
        form.ForeColor = Text;
        form.AutoScaleMode = AutoScaleMode.Dpi;
    }

    public static Button Button(string text, bool primary = false)
    {
        var button = new Button
        {
            Text = text, AutoSize = true, MinimumSize = new Size(80, 36),
            Padding = new Padding(10, 3, 10, 3), FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Accent : Surface, ForeColor = primary ? Color.White : Text,
            UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderColor = primary ? Accent : Border;
        return button;
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
}

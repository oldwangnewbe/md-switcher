namespace MDSwitcher;

internal static class PerformanceConfirmation
{
    public static DialogResult Show(Control owner, string description)
    {
        using var dialog = new Form
        {
            Text = "同时应用异画演出？", ClientSize = new(440, 140), StartPosition = FormStartPosition.CenterParent,
            FormBorderStyle = FormBorderStyle.FixedDialog, ShowInTaskbar = false, MaximizeBox = false, MinimizeBox = false,
        };
        Ui.Style(dialog);
        var layout = Ui.Stack(SizeType.Percent, SizeType.AutoSize);
        layout.Padding = new(16);
        var text = Ui.Label(description);
        text.MaximumSize = new(400, 0);
        text.Margin = new(0, 5, 0, 12);
        var together = Ui.Button("应用异画和演出", primary: true);
        together.DialogResult = DialogResult.Yes;
        var artworkOnly = Ui.Button("仅应用异画");
        artworkOnly.DialogResult = DialogResult.No;
        var cancel = Ui.Button("取消");
        cancel.DialogResult = DialogResult.Cancel;
        layout.Controls.Add(text, 0, 0);
        layout.Controls.Add(Ui.Row(together, artworkOnly, cancel), 0, 1);
        dialog.AcceptButton = together;
        dialog.CancelButton = cancel;
        dialog.Controls.Add(layout);
        return dialog.ShowDialog(owner);
    }
}

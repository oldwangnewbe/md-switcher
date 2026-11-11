namespace MDSwitcher;

internal sealed partial class MainWindow
{
    private readonly Button royalFinish = Ui.Button("动态镜碎");
    private readonly RoyalFinishSettings royalSettings = new(StateDirectory);
    private readonly System.Windows.Forms.Timer royalTimer = new() { Interval = 1200 };
    private RoyalFinishPage? royalPage;
    private (Installation Install, SteamRoyalFinishMonitor Monitor)? royalMonitor;
    private string? royalSettingsError;
    private string? royalLoadResult;
    private bool checkingRoyal;

    private void LoadRoyalSettings()
    {
        try { royalSettings.Load(); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            royalSettingsError = $"动态镜碎设置读取失败。{error.Message}";
        }
    }

    private void ShowRoyalFinish()
    {
        if (royalSettingsError is not null) throw new InvalidDataException(royalSettingsError);
        if (install is null || proDirectory is null)
            throw new InvalidOperationException("请先在设置中确认 Master Duel 和 MDPro3 的目录。");
        if (accounts.SelectedItem is not Account selected)
            throw new InvalidOperationException("请先在「账号切换」选择一个 Steam 账号。");
        if (royalPage is not null)
        {
            royalPage.ReloadCollections();
            Navigate(royalFinish, royalPage);
            return;
        }
        var resource = CurrentResources ?? throw new InvalidOperationException("请先设置并下载主账号的游戏资源，用于读取卡库。");
        var source = GameResources.Cache(install, resource.MainFolder);
        var page = new RoyalFinishPage(new CardEngine(StateDirectory, proDirectory), source,
            Path.Combine(StateDirectory, "artwork-collections.json"), royalSettings, selected.Id, AccountLabel(selected),
            accounts.Items.Select(account => account.Id).ToArray());
        if (royalLoadResult is not null) page.ShowLoadResult(royalLoadResult);
        page.BusyChanged += UpdateButtons;
        royalPage = page;
        Navigate(royalFinish, page);
    }

    private async Task PollRoyalFinishAsync()
    {
        if (checkingRoyal || busy || install is not { } current || royalSettingsError is not null) return;
        if (royalMonitor is not { } existing || existing.Install != current)
        {
            royalMonitor = (current, new SteamRoyalFinishMonitor(current, StateDirectory));
            royalLoadResult = null;
        }
        checkingRoyal = true;
        try
        {
            var monitor = royalMonitor.Value.Monitor;
            var selections = royalSettings.Accounts;
            var result = await Task.Run(() => monitor.Poll(selections));
            if (result is not null) ShowResult(result);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException
            or TimeoutException or System.ComponentModel.Win32Exception)
        {
            var message = $"动态镜碎未加载。{error.Message}";
            if (royalLoadResult != message) ShowResult(message);
        }
        finally { checkingRoyal = false; }

        void ShowResult(string message)
        {
            if (IsDisposed || install != current || busy) return;
            royalLoadResult = message;
            royalPage?.ShowLoadResult(message);
            if (activePage == accountPage) status.Text = message;
        }
    }
}

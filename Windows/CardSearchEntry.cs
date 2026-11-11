using System.Text;

namespace MDSwitcher;

internal sealed class CardSearchEntry(Card card)
{
    public Card Card { get; } = card;
    public string[] Names { get; } = new[] { card.Id, card.MasterName ?? "", card.ProName ?? "" }
        .Concat(card.Codes.Select(code => code.ToString()))
        .Concat(card.MasterIDs.Select(id => id.ToString()))
        .Concat(card.Cid is int cid ? [cid.ToString()] : [])
        .Select(Normalize).Distinct().ToArray();
    public string[] Series { get; } = card.Series.Select(Normalize).ToArray();

    public int Rank(string query)
    {
        if (query.Length == 0 || Names.Contains(query, StringComparer.Ordinal)) return 0;
        if (Series.Any(series => series.Contains(query, StringComparison.Ordinal))) return 1;
        if (Names.Any(name => name.StartsWith(query, StringComparison.Ordinal))) return 2;
        return Names.Any(name => name.Contains(query, StringComparison.Ordinal)) ? 3 : -1;
    }

    public static string Normalize(string input) =>
        new(input.Normalize(NormalizationForm.FormKC).ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
}

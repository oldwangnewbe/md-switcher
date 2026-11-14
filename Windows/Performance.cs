using System.Text;

namespace MDSwitcher;

internal sealed record Performance(int Cid, int ArtworkID, string Name, int? Donor, int? ActivationStyle, bool AddsSummon)
{
    internal const string Catalog = "70/70e201b4";
    internal const string Trigger = "60/60c98f0d";

    public (int Card, bool Activation) Slot => (Cid, ActivationStyle.HasValue);
    public string Category => AddsSummon ? "新增召唤演出" : ActivationStyle.HasValue ? "发动演出替换" : "召唤演出替换";
    public string Spec => $"{Cid}:{ArtworkID}:{Donor ?? 0}:{(AddsSummon ? 4 : ActivationStyle ?? 0)}";

    public IEnumerable<string> Paths()
    {
        if (ActivationStyle is not int style) return SummonPaths(Cid);
        var token = $"Ef{Cid:00000}";
        var root = $"Duel/Timeline/Card/tcg/{token}/{token}";
        string[] suffixes = style switch
        {
            1 => [""],
            2 => ["", "_4x3"],
            3 => ["", "Op"],
            5 => ["", "_4x3", "Op"],
            _ => throw new InvalidDataException("发动演出格式异常。")
        };
        return suffixes.Select(suffix => AssetName(root + suffix));
    }

    public static IEnumerable<string> SummonPaths(int cid) => new[] { "SD", "HighEnd_HD" }.Select(quality =>
        AssetName($"Duel/Timeline/Duel/MonsterCutIn/tcg/P{cid}/{quality}/P{cid}"));

    private static string AssetName(string name)
    {
        var crc = uint.MaxValue;
        foreach (var b in Encoding.UTF8.GetBytes(name))
        {
            crc ^= b;
            for (var bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
        }
        var hex = (~crc).ToString("x8");
        return $"{hex[..2]}/{hex}";
    }
}

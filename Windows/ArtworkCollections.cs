using System.Text.Json;

namespace MDSwitcher;

internal sealed record ArtworkCollection(string Id, string Name, Dictionary<int, int> Choices)
{
    public override string ToString() => Name;

    public static ArtworkCollection[] Load(string file)
    {
        ArtworkCollection[] presets =
        [
            new("sky-striker", "闪刀姬", new()
            {
                [13670] = 26077389, [14829] = 37351134, [13668] = 63288574, [13669] = 90673289,
                [13763] = 8491309, [13671] = 63166096, [17034] = 9726841, [13675] = 98338153,
            }),
            new("branded", "烙印", new()
            {
                [15245] = 68468460, [16195] = 62962631, [16493] = 55273561,
                [17069] = 44146296, [17767] = 95515790, [15239] = 60303689,
            }),
            new("dark-magician", "黑魔导", new()
            {
                [4041] = 46986418, [4766] = 38033123, [5628] = 98502114, [11151] = 43892409,
                [12456] = 47222537, [14908] = 59514117, [14952] = 37818795, [22692] = 41350418,
            }),
        ];
        if (!File.Exists(file)) return presets;
        var saved = JsonSerializer.Deserialize<ArtworkCollection[]>(File.ReadAllText(file));
        if (saved is null || saved.Any(item => item is null || string.IsNullOrWhiteSpace(item.Id) ||
                string.IsNullOrWhiteSpace(item.Name) || item.Choices is null ||
                item.Choices.Any(pair => pair.Key <= 0 || pair.Value <= 0)) ||
            saved.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != saved.Length)
            throw new InvalidDataException("异画合集配置格式异常。");
        return presets.Select(preset => saved.FirstOrDefault(item => item.Id == preset.Id) ?? preset)
            .Concat(saved.Where(item => presets.All(preset => preset.Id != item.Id))).ToArray();
    }

    public static void Save(string file, ArtworkCollection[] collections) =>
        SteamSession.AtomicWrite(file, JsonSerializer.Serialize(collections));
}

using System.Text;
using System.Text.RegularExpressions;

namespace MDSwitcher;

internal sealed record VdfField(string Name, string? Value, int Offset, int Length, VdfField[]? Fields);

internal static partial class Vdf
{
    public static VdfField? Field(this VdfField[]? fields, string name) =>
        fields?.FirstOrDefault(field => field.Name.Equals(name, StringComparison.OrdinalIgnoreCase));

    public static VdfField[] Parse(string text)
    {
        var source = text.TrimStart('\uFEFF');
        var bomLength = text.Length - source.Length;
        var tokens = TokenPattern().Matches(source).Where(match =>
            !char.IsWhiteSpace(match.Value[0]) && !match.Value.StartsWith("//")).ToArray();
        var cursor = 0;
        return Block(false, 0);

        VdfField[] Block(bool nested, int depth)
        {
            if (depth > 32) throw Invalid();
            List<VdfField> fields = [];
            while (cursor < tokens.Length)
            {
                var key = tokens[cursor++];
                if (key.Value == "}" && nested)
                    return fields.ToArray();
                if (key.Value is "{" or "}" || cursor >= tokens.Length)
                    throw Invalid();
                var value = tokens[cursor++];
                if (value.Value == "}")
                    throw Invalid();
                if (value.Value == "{")
                {
                    var entries = Block(true, depth + 1);
                    fields.Add(new(Decode(key.Value), null, bomLength + tokens[cursor - 1].Index, 0, entries));
                }
                else
                {
                    fields.Add(new(Decode(key.Value), Decode(value.Value), bomLength + value.Index, value.Length, null));
                }
            }
            if (nested) throw Invalid();
            return fields.ToArray();
        }
    }

    private static string Decode(string value)
    {
        if (!value.StartsWith('"')) return value;
        if (value.Length < 2 || !value.EndsWith('"')) throw Invalid();
        var result = new StringBuilder();
        for (var index = 1; index < value.Length - 1; index++)
        {
            var character = value[index];
            if (character == '\\' && index + 1 < value.Length - 1 && value[index + 1] is '\\' or '"')
                character = value[++index];
            result.Append(character);
        }
        return result.ToString();
    }

    private static InvalidDataException Invalid() => new("Steam 配置格式异常。");

    [GeneratedRegex("""\s+|//[^\r\n]*|[{}]|"(?:\\[^\r\n]|[^"\\\r\n])*"|[^\s{}"]+|["]""")]
    private static partial Regex TokenPattern();
}

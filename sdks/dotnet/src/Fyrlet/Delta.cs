using System.Text.Json;

namespace Fyrlet;

/// <summary>Compact <c>delta-v1</c> patches. Views are immutable: every call returns new containers.</summary>
internal static class Delta
{
    private const int MaxItems = 100;

    /// <summary>Applies <paramref name="patch"/> to <paramref name="data"/>; returns null if the patch is invalid.</summary>
    public static JsonElement? Apply(JsonElement? data, JsonElement patch)
    {
        if (data is not { ValueKind: JsonValueKind.Array } view || view.GetArrayLength() > MaxItems || patch.ValueKind != JsonValueKind.Object) return null;
        foreach (var property in patch.EnumerateObject())
            if (property.Name is not ("a" or "c" or "r" or "o")) return null;

        var records = new Dictionary<string, JsonElement>();
        var ids = new List<string>();
        foreach (var entry in view.EnumerateArray())
        {
            if (Id(entry) is not { } id || !records.TryAdd(id, entry)) return null;
            ids.Add(id);
        }
        var touched = new HashSet<string>();

        List<JsonElement>? List(string key)
        {
            if (!patch.TryGetProperty(key, out var value)) return new();
            if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > MaxItems) return null;
            return value.EnumerateArray().ToList();
        }

        if (List("r") is not { } removed || List("a") is not { } added || List("c") is not { } updates) return null;
        foreach (var value in removed)
        {
            if (value.ValueKind != JsonValueKind.String || !records.Remove(value.GetString()!) || !touched.Add(value.GetString()!)) return null;
        }
        foreach (var value in added)
        {
            if (Id(value) is not { } id || records.ContainsKey(id) || !touched.Add(id)) return null;
            records[id] = value;
        }
        foreach (var change in updates)
        {
            if (change.ValueKind != JsonValueKind.Array) return null;
            var parts = change.EnumerateArray().ToList();
            if (parts.Count is not (2 or 3) || parts[0].ValueKind != JsonValueKind.String || parts[1].ValueKind != JsonValueKind.Object) return null;
            var id = parts[0].GetString()!;
            if (parts[1].TryGetProperty("id", out _) || !records.TryGetValue(id, out var previous) || !touched.Add(id)) return null;
            var cleared = new List<string>();
            if (parts.Count == 3)
            {
                if (parts[2].ValueKind != JsonValueKind.Array) return null;
                foreach (var name in parts[2].EnumerateArray())
                {
                    if (name.ValueKind != JsonValueKind.String) return null;
                    var key = name.GetString()!;
                    if (key == "id" || parts[1].TryGetProperty(key, out _) || cleared.Contains(key)) return null;
                    cleared.Add(key);
                }
            }
            var updated = new Dictionary<string, JsonElement>();
            foreach (var property in previous.EnumerateObject()) updated[property.Name] = property.Value;
            foreach (var property in parts[1].EnumerateObject()) updated[property.Name] = property.Value;
            foreach (var key in cleared) updated.Remove(key);
            records[id] = JsonSerializer.SerializeToElement(updated);
        }

        var order = ids;
        if (patch.TryGetProperty("o", out _))
        {
            if (List("o") is not { } explicitOrder || explicitOrder.Any(v => v.ValueKind != JsonValueKind.String)) return null;
            order = explicitOrder.Select(v => v.GetString()!).ToList();
        }
        if (records.Count > MaxItems || order.Count != records.Count || order.Distinct().Count() != order.Count || order.Any(id => !records.ContainsKey(id))) return null;
        return JsonSerializer.SerializeToElement(order.Select(id => records[id]).ToList());
    }

    private static string? Id(JsonElement record) =>
        record.ValueKind == JsonValueKind.Object && record.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String ? id.GetString() : null;
}

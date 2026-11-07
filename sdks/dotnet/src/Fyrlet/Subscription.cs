using System.Text.Json;

namespace Fyrlet;

/// <summary>The lifecycle of a subscription.</summary>
public enum SubscriptionStatus
{
    /// <summary>The initial connection.</summary>
    Connecting,
    /// <summary>The subscription holds a current snapshot.</summary>
    Ready,
    /// <summary>The previous data is retained while the connection is rebuilt.</summary>
    Recovering,
    /// <summary>Terminal: data is cleared and <see cref="SubscriptionState.Error"/> explains why.</summary>
    Error,
    /// <summary>Terminal: the subscription or client was closed.</summary>
    Closed,
}

/// <summary>What a listener sees. <see cref="Data"/> is immutable; a later delta creates a new value.</summary>
public sealed record SubscriptionState(
    SubscriptionStatus Status = SubscriptionStatus.Connecting,
    JsonElement? Data = null,
    ApiException? Error = null,
    string? Generation = null,
    long Seq = 0)
{
    /// <summary>Deserializes <see cref="Data"/> into your own type.</summary>
    public T? Decode<T>(JsonSerializerOptions? options = null) =>
        Data is { } data ? data.Deserialize<T>(options ?? FyrletJson.Options) : default;
}

/// <summary>Case-insensitive property matching, so <c>record Item(string Id, string Text)</c> reads <c>{"id":..}</c>.</summary>
public static class FyrletJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
}

internal abstract record Applied
{
    public sealed record Nothing : Applied;
    public sealed record Ack(string Generation, long Seq) : Applied;
    public sealed record Reconnect : Applied;
}

internal sealed class Entry
{
    public Entry(string id, string name, object parameters, bool wantDelta)
    {
        Id = id; Name = name; Params = parameters; WantDelta = wantDelta;
    }

    public string Id { get; }
    public string Name { get; }
    public object Params { get; }
    public bool WantDelta { get; }
    public string Topic => "subscription:" + Id;
    public SubscriptionState State { get; set; } = new();
    public Dictionary<int, Action<SubscriptionState>> Listeners { get; set; } = new();
    public int NextListener { get; set; }
    public Connection? Connection { get; set; }
    public int JoinFailures { get; set; }
    public Timer? Rejoin { get; set; }
    private bool _delta;

    private static long? Integer(JsonElement element, string name) =>
        element.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : null;

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public Applied ApplySnapshot(JsonElement? payload, (string Project, string Subject)? identity, bool initial)
    {
        if (payload is not { ValueKind: JsonValueKind.Object } p || Integer(p, "protocol_version") != 1 || Text(p, "subscription_id") != Id ||
            identity is not { } who || Text(p, "project_id") != who.Project || Text(p, "subject_id") != who.Subject ||
            Text(p, "generation") is not { } generation || Integer(p, "seq") is not { } seq || seq < 1 || !p.TryGetProperty("data", out var data))
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription snapshot");
        if (!initial && generation != State.Generation) return new Applied.Nothing();
        if (initial) _delta = Text(p, "delivery") == "delta-v1";
        if (initial || seq > State.Seq) State = new SubscriptionState(SubscriptionStatus.Ready, data, null, generation, seq);
        return new Applied.Ack(generation, seq);
    }

    public Applied ApplyDelta(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object) throw new ApiException("PROTOCOL_ERROR", "Invalid subscription delta");
        if (Text(payload, "g") != State.Generation) return new Applied.Nothing();
        if (!_delta || Integer(payload, "s") is not { } seq || Integer(payload, "b") is not { } baseSeq || seq < 2 || baseSeq < 1 ||
            seq != baseSeq + 1 || State.Generation is not { } generation)
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription delta sequence");
        if (seq <= State.Seq) return new Applied.Ack(generation, seq);
        if (baseSeq != State.Seq) return new Applied.Reconnect();
        if (!payload.TryGetProperty("p", out var patch) || Delta.Apply(State.Data, patch) is not { } data)
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription delta");
        State = new SubscriptionState(SubscriptionStatus.Ready, data, null, generation, seq);
        return new Applied.Ack(generation, seq);
    }
}

/// <summary>A handle to one realtime subscription. Members are safe to use from any thread.</summary>
public sealed class Subscription
{
    private readonly FyrletClient _client;
    internal Entry Entry { get; }

    internal Subscription(FyrletClient client, Entry entry) { _client = client; Entry = entry; }

    /// <summary>The current state.</summary>
    public SubscriptionState State => _client.Locked(() => Entry.State);

    /// <summary>
    /// Registers a listener. It receives the current state first, then every change, serially on a dedicated
    /// task, so it may call back into the client. Dispose the result to remove it.
    /// </summary>
    public IDisposable OnChange(Action<SubscriptionState> listener) => _client.AddListener(Entry, listener);

    /// <summary>Asks the server for a fresh snapshot. Returns once the server accepted it; data arrives via <see cref="OnChange"/>.</summary>
    public Task RefreshAsync(CancellationToken cancellation = default) => _client.RefreshAsync(Entry, cancellation);

    /// <summary>Ends this subscription. Safe to call more than once.</summary>
    public void Unsubscribe() => _client.Unsubscribe(Entry);
}

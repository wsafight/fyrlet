using System.Text.Json;

namespace Fyrlet;

/// <summary>A failure reported by the server or detected by the SDK.</summary>
public class ApiException : Exception
{
    public string Code { get; }
    public IReadOnlyDictionary<string, JsonElement> Details { get; }
    public bool Retryable { get; }
    public int Status { get; }
    public string? RequestId { get; }

    public ApiException(string code, string message, bool retryable = false, int status = 0, string? requestId = null,
        IReadOnlyDictionary<string, JsonElement>? details = null, Exception? inner = null) : base(message, inner)
    {
        Code = code;
        Retryable = retryable;
        Status = status;
        RequestId = requestId;
        Details = details ?? new Dictionary<string, JsonElement>();
    }

    internal static ApiException Network(string message = "The service could not be reached") =>
        new("NETWORK_ERROR", message, retryable: true);

    internal static ApiException FromWire(JsonElement? error, int status, string? requestId)
    {
        if (error is { ValueKind: JsonValueKind.Object } e &&
            e.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.String &&
            e.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
        {
            var details = new Dictionary<string, JsonElement>();
            if (e.TryGetProperty("details", out var raw) && raw.ValueKind == JsonValueKind.Object)
                foreach (var property in raw.EnumerateObject()) details[property.Name] = property.Value.Clone();
            var retryable = e.TryGetProperty("retryable", out var flag) && flag.ValueKind == JsonValueKind.True;
            return new ApiException(code.GetString()!, message.GetString()!, retryable, status, requestId, details);
        }
        return new ApiException("PROTOCOL_ERROR", "Invalid error response", status: status, requestId: requestId);
    }

    /// <summary>Converts a Phoenix error reply (<c>{"error": {...}, "status": 409}</c>).</summary>
    internal static ApiException Channel(JsonElement? response)
    {
        if (response is { ValueKind: JsonValueKind.Object } r && r.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
        {
            var status = r.TryGetProperty("status", out var s) && s.ValueKind == JsonValueKind.Number && s.TryGetInt32(out var n) ? n : 0;
            return FromWire(error, status, null);
        }
        return new ApiException("PROTOCOL_ERROR", "The server returned an invalid channel response");
    }

    internal static ApiException From(Exception error) => error as ApiException ?? Network();
}

/// <summary>
/// A write was dispatched but its result is unknown. Use <see cref="FyrletClient.RecoverAsync"/> with
/// <see cref="IdempotencyKey"/> before deciding to submit it again.
/// </summary>
public sealed class OutcomeUnknownException : ApiException
{
    public string Operation { get; }
    public string IdempotencyKey { get; }

    public OutcomeUnknownException(string operation, string idempotencyKey, Exception cause)
        : base(ApiException.From(cause).Code, "The operation outcome is unknown", false, ApiException.From(cause).Status,
            ApiException.From(cause).RequestId, ApiException.From(cause).Details.ToDictionary(p => p.Key, p => p.Value), cause)
    {
        Operation = operation;
        IdempotencyKey = idempotencyKey;
    }
}

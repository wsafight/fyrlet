using System.Text.Json;

namespace Fyrlet;

/// <summary>A short-lived user session issued by a trusted backend.</summary>
public sealed record UserSession(string Token, string ProjectId, string SubjectId, string SessionId, string ExpiresAt);

/// <summary>Session exchange for trusted backends. Never ship the service key in an app.</summary>
public sealed class SessionService
{
    private readonly string _endpoint;
    private readonly Dictionary<string, string> _headers;
    private readonly HttpClient _http;
    private readonly TimeSpan _timeout;

    public SessionService(string endpoint, string serviceKey, TimeSpan? timeout = null, HttpClient? http = null)
    {
        if (!serviceKey.StartsWith("rtk_", StringComparison.Ordinal)) throw new ArgumentException("Expected a backend service key");
        _endpoint = Http.EndpointUrl(endpoint);
        _headers = new() { ["authorization"] = $"Bearer {serviceKey}" };
        _timeout = timeout ?? TimeSpan.FromSeconds(10);
        _http = http ?? Http.NewClient();
    }

    public async Task<UserSession> IssueSessionAsync(string externalSubject, string? issuer = null, int? ttlSeconds = null,
        CancellationToken cancellation = default)
    {
        var body = new Dictionary<string, object> { ["external_subject"] = externalSubject };
        if (issuer is not null) body["issuer"] = issuer;
        if (ttlSeconds is not null) body["ttl_seconds"] = ttlSeconds;
        var envelope = await Http.SendAsync(_http, HttpMethod.Post, _endpoint + "/api/v1/sessions", _headers, body, _timeout, cancellation).ConfigureAwait(false);
        string? Field(string name) => envelope.Data.ValueKind == JsonValueKind.Object && envelope.Data.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        return new UserSession(
            Field("token") ?? throw Invalid(), Field("project_id") ?? throw Invalid(), Field("subject_id") ?? throw Invalid(),
            Field("session_id") ?? throw Invalid(), Field("expires_at") ?? throw Invalid());
    }

    public async Task<bool> RevokeSessionAsync(string sessionId, CancellationToken cancellation = default)
    {
        var envelope = await Http.SendAsync(_http, HttpMethod.Delete, _endpoint + "/api/v1/sessions/" + Uri.EscapeDataString(sessionId),
            _headers, null, _timeout, cancellation).ConfigureAwait(false);
        return envelope.Data.ValueKind == JsonValueKind.Object && envelope.Data.TryGetProperty("revoked", out var revoked) && revoked.ValueKind == JsonValueKind.True;
    }

    private static ApiException Invalid() => new("PROTOCOL_ERROR", "Invalid session response");
}

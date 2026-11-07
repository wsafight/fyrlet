using System.Net;
using System.Text;
using System.Text.Json;

namespace Fyrlet;

internal sealed record Envelope(JsonElement Data, string? Outcome, string? RequestId);

internal static class Http
{
    public static string EndpointUrl(string endpoint)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var url) || (url.Scheme != "http" && url.Scheme != "https") ||
            url.UserInfo.Length > 0 || url.Query.Length > 0 || url.Fragment.Length > 0)
            throw new ArgumentException("endpoint must be an HTTP(S) base URL without credentials, query or fragment");
        return endpoint.TrimEnd('/');
    }

    /// <summary>Redirects are never followed: they could forward bearer credentials to another host.</summary>
    public static HttpClient NewClient() => new(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false });

    public static async Task<Envelope> SendAsync(HttpClient client, HttpMethod method, string url,
        IReadOnlyDictionary<string, string> headers, object? body, TimeSpan timeout, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(method, url);
        request.Headers.TryAddWithoutValidation("accept", "application/json");
        foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
        if (body is not null)
            request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        using var timer = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timer.CancelAfter(timeout);
        string text;
        HttpStatusCode status;
        try
        {
            using var response = await client.SendAsync(request, timer.Token).ConfigureAwait(false);
            status = response.StatusCode;
            text = await response.Content.ReadAsStringAsync(timer.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new ApiException("TIMEOUT", "The request timed out", retryable: true);
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            throw ApiException.Network();
        }

        JsonElement root;
        try { root = JsonDocument.Parse(text).RootElement; }
        catch (JsonException) { throw new ApiException("PROTOCOL_ERROR", "Expected a JSON response", status: (int)status); }
        if (root.ValueKind != JsonValueKind.Object)
            throw new ApiException("PROTOCOL_ERROR", "Expected a response envelope", status: (int)status);

        var requestId = root.TryGetProperty("request_id", out var id) && id.ValueKind == JsonValueKind.String ? id.GetString() : null;
        var hasError = root.TryGetProperty("error", out var error2);
        if ((int)status is < 200 or >= 300 || hasError)
        {
            if (hasError) throw ApiException.FromWire(error2, (int)status, requestId);
            throw new ApiException("HTTP_ERROR", "The request was rejected", status: (int)status, requestId: requestId);
        }
        if (!root.TryGetProperty("data", out var data))
            throw new ApiException("PROTOCOL_ERROR", "Missing response data", status: (int)status);
        var outcome = root.TryGetProperty("outcome", out var o) && o.ValueKind == JsonValueKind.String ? o.GetString() : null;
        return new Envelope(data.Clone(), outcome, requestId);
    }
}

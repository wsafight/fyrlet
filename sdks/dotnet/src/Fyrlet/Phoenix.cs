using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Fyrlet;

internal sealed record Frame(string? JoinRef, string? Ref, string Topic, string Event, JsonElement Payload);

internal delegate void Reply(string status, JsonElement? response);

internal static class Wire
{
    /// <summary>Decodes one Phoenix frame or a <c>{"batch":[...]}</c> wrapper, validating every member.</summary>
    public static List<Frame>? Decode(string raw)
    {
        JsonElement root;
        try { root = JsonDocument.Parse(raw).RootElement; } catch (JsonException) { return null; }
        List<JsonElement> members;
        if (root.ValueKind == JsonValueKind.Object)
        {
            if (root.EnumerateObject().Count() != 1 || !root.TryGetProperty("batch", out var batch) || batch.ValueKind != JsonValueKind.Array) return null;
            members = batch.EnumerateArray().ToList();
        }
        else members = new() { root };
        if (members.Count is 0 or > 64) return null;
        var frames = new List<Frame>();
        foreach (var member in members)
        {
            if (member.ValueKind != JsonValueKind.Array || member.GetArrayLength() != 5) return null;
            var p = member.EnumerateArray().ToArray();
            bool Optional(JsonElement e) => e.ValueKind is JsonValueKind.Null or JsonValueKind.String;
            if (!Optional(p[0]) || !Optional(p[1]) || p[2].ValueKind != JsonValueKind.String || p[3].ValueKind != JsonValueKind.String ||
                p[4].ValueKind != JsonValueKind.Object) return null;
            frames.Add(new Frame(p[0].GetString(), p[1].GetString(), p[2].GetString()!, p[3].GetString()!, p[4]));
        }
        return frames;
    }

    public static Uri SocketUrl(string endpoint, string projectId) =>
        new("ws" + endpoint["http".Length..] + "/socket/websocket?project_id=" + Uri.EscapeDataString(projectId) + "&vsn=2.0.0");

    public static string AuthProtocol(string token) =>
        "base64url.bearer.phx." + Convert.ToBase64String(Encoding.UTF8.GetBytes(token)).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

/// <summary>One authenticated socket. <c>OnFrame</c> and <c>OnClose</c> run on the reader task, in order.</summary>
internal sealed class Connection
{
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(30);

    private readonly ClientWebSocket _socket;
    private readonly TimeSpan _timeout;
    private readonly object _lock = new();
    private readonly SemaphoreSlim _send = new(1, 1);
    private readonly Dictionary<string, (Reply Reply, Timer Timer)> _pending = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly Action<Connection, Frame> _onFrame;
    private readonly Action<Connection, ApiException?> _onClose;
    private int _refs;
    private bool _closed;

    private Connection(ClientWebSocket socket, TimeSpan timeout, Action<Connection, Frame> onFrame, Action<Connection, ApiException?> onClose)
    {
        _socket = socket; _timeout = timeout; _onFrame = onFrame; _onClose = onClose;
    }

    public static async Task<Connection> OpenAsync(string endpoint, string projectId, string token, TimeSpan timeout,
        Action<Connection, Frame> onFrame, Action<Connection, ApiException?> onClose, CancellationToken cancellation)
    {
        var socket = new ClientWebSocket();
        socket.Options.AddSubProtocol("phoenix");
        socket.Options.AddSubProtocol(Wire.AuthProtocol(token));
        socket.Options.KeepAliveInterval = TimeSpan.Zero; // Phoenix heartbeats replace protocol pings
        using var timer = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timer.CancelAfter(timeout);
        try
        {
            await socket.ConnectAsync(Wire.SocketUrl(endpoint, projectId), timer.Token).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            socket.Dispose();
            if (cancellation.IsCancellationRequested) throw;
            if (error is WebSocketException { Message: var m } && (m.Contains("401") || m.Contains("403")))
                throw new ApiException("UNAUTHENTICATED", "The socket rejected the session", status: m.Contains("401") ? 401 : 403);
            throw ApiException.Network();
        }
        var connection = new Connection(socket, timeout, onFrame, onClose);
        _ = Task.Run(connection.ReadLoop);
        _ = Task.Run(connection.HeartbeatLoop);
        return connection;
    }

    private string NextRef() { lock (_lock) return (++_refs).ToString(); }

    private bool Register(string reference, Reply reply)
    {
        lock (_lock)
        {
            if (_closed) return false;
            var timer = new Timer(_ =>
            {
                (Reply Reply, Timer Timer) entry;
                lock (_lock) { if (!_pending.Remove(reference, out entry)) return; }
                entry.Timer.Dispose();
                entry.Reply("timeout", null);
            }, null, _timeout, Timeout.InfiniteTimeSpan);
            _pending[reference] = (reply, timer);
            return true;
        }
    }

    private async Task SendAsync(object?[] parts)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(parts);
        try
        {
            await _send.WaitAsync(_stop.Token).ConfigureAwait(false);
            try { await _socket.SendAsync(bytes, WebSocketMessageType.Text, true, _stop.Token).ConfigureAwait(false); }
            finally { _send.Release(); }
        }
        catch (Exception)
        {
            Shutdown(ApiException.Network("The connection was interrupted"), notify: true);
        }
    }

    /// <summary>Sends an event; <paramref name="reply"/> receives "ok", "error" or "timeout" exactly once.</summary>
    public bool Push(string topic, string eventName, object payload, Reply reply)
    {
        var reference = NextRef();
        if (!Register(reference, reply)) return false;
        _ = SendAsync(new object?[] { null, reference, topic, eventName, payload });
        return true;
    }

    public bool Join(string topic, object payload, Reply reply)
    {
        var reference = NextRef();
        if (!Register(reference, reply)) return false;
        _ = SendAsync(new object?[] { reference, reference, topic, "phx_join", payload });
        return true;
    }

    /// <summary>Fire-and-forget event with no ref, such as <c>ack</c>.</summary>
    public void Notify(string topic, string eventName, object payload) =>
        _ = SendAsync(new object?[] { null, null, topic, eventName, payload });

    public void Leave(string topic) => _ = SendAsync(new object?[] { null, NextRef(), topic, "phx_leave", new { } });

    public void Close() => Shutdown(null, notify: false);

    private async Task ReadLoop()
    {
        var failure = ApiException.Network("The connection was interrupted");
        var buffer = new byte[16 * 1024];
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                using var message = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await _socket.ReceiveAsync(buffer, _stop.Token).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close) { Shutdown(failure, notify: true); return; }
                    message.Write(buffer, 0, result.Count);
                    if (message.Length > 4 * 1024 * 1024) throw new InvalidDataException("message too large");
                } while (!result.EndOfMessage);

                if (Wire.Decode(Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length)) is not { } frames)
                {
                    failure = new ApiException("PROTOCOL_ERROR", "Invalid transport frame");
                    break;
                }
                foreach (var frame in frames) Dispatch(frame);
            }
        }
        catch (Exception) { /* closed or interrupted */ }
        Shutdown(failure, notify: true);
    }

    private void Dispatch(Frame frame)
    {
        if (frame.Event == "phx_reply" && frame.Ref is { } reference)
        {
            (Reply Reply, Timer Timer) entry;
            lock (_lock) { if (!_pending.Remove(reference, out entry)) return; }
            entry.Timer.Dispose();
            var status = frame.Payload.TryGetProperty("status", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString()! : "error";
            JsonElement? response = frame.Payload.TryGetProperty("response", out var r) ? r : null;
            entry.Reply(status, response);
            return;
        }
        _onFrame(this, frame);
    }

    private async Task HeartbeatLoop()
    {
        try
        {
            using var ticker = new PeriodicTimer(HeartbeatInterval);
            while (await ticker.WaitForNextTickAsync(_stop.Token).ConfigureAwait(false))
            {
                var sent = Push("phoenix", "heartbeat", new { }, (status, _) =>
                {
                    if (status == "timeout") Shutdown(ApiException.Network("Heartbeat timed out"), notify: true);
                });
                if (!sent) return;
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Shutdown(ApiException? failure, bool notify)
    {
        List<(Reply Reply, Timer Timer)> waiters;
        lock (_lock)
        {
            if (_closed) return;
            _closed = true;
            waiters = _pending.Values.ToList();
            _pending.Clear();
        }
        _stop.Cancel();
        try { _socket.Abort(); _socket.Dispose(); } catch (Exception) { /* best effort */ }
        // Callbacks run on the thread pool because the caller may hold the client lock they take.
        foreach (var waiter in waiters) { waiter.Timer.Dispose(); var reply = waiter.Reply; _ = Task.Run(() => reply("timeout", null)); }
        if (notify) _ = Task.Run(() => _onClose(this, failure));
    }
}

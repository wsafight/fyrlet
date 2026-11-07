using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace Fyrlet;

/// <summary>Configuration for a <see cref="FyrletClient"/>.</summary>
public sealed class FyrletOptions
{
    /// <summary>HTTP(S) base URL of the Fyrlet server.</summary>
    public required string Endpoint { get; init; }
    /// <summary>The project this client is bound to.</summary>
    public required string ProjectId { get; init; }
    /// <summary>
    /// Returns a short-lived user session token (<c>rts_...</c>). With <c>forceRefresh</c> set, revalidate the host
    /// login and obtain a new session, or throw <c>ApiException("UNAUTHENTICATED", ...)</c> to stop recovery.
    /// </summary>
    public required Func<bool, CancellationToken, Task<string>> GetToken { get; init; }
    /// <summary>Bounds each HTTP request and socket reply. Default 10 seconds.</summary>
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>Backoff before reconnect attempt n (1-based). Default 250 ms doubling to 30 s.</summary>
    public Func<int, TimeSpan>? RetryDelay { get; init; }
    /// <summary>Request <c>delta-v1</c> field deltas. Disable to receive full snapshots only.</summary>
    public bool Delta { get; init; } = true;
    /// <summary>Optional capabilities to negotiate, as name to version.</summary>
    public IReadOnlyDictionary<string, int>? Capabilities { get; init; }
    /// <summary>Generates idempotency keys and subscription IDs.</summary>
    public Func<string> NewId { get; init; } = () => Guid.NewGuid().ToString();
    /// <summary>Overrides the HttpClient. It must not follow redirects.</summary>
    public HttpClient? HttpClient { get; init; }
    /// <summary>Receives exceptions thrown by listeners.</summary>
    public Action<Exception>? OnListenerError { get; init; }
}

/// <summary>Options for one operation.</summary>
public sealed class CallOptions
{
    /// <summary>Reuse a key, for example when retrying after an unknown outcome.</summary>
    public string? IdempotencyKey { get; init; }
}

public enum MutationStatus
{
    /// <summary>A successful read.</summary>
    Completed,
    /// <summary>A write committed to the database.</summary>
    Committed,
    /// <summary>A Run or ingest accepted for later execution.</summary>
    Accepted,
    /// <summary>A definite failure: nothing was written.</summary>
    Failed,
    /// <summary>The write was dispatched but its result was not seen. Use <see cref="Mutation.RecoverAsync"/>.</summary>
    Unknown,
}

public sealed record MutationState(MutationStatus Status, JsonElement? Data = null, Exception? Error = null);

/// <summary>A stored receipt: Committed or Accepted with the original data, or Unknown.</summary>
public sealed record RecoveryResult(MutationStatus Status, JsonElement? Data = null);

/// <summary>Keeps the outcome of an operation so an unknown result can be recovered later.</summary>
public sealed class Mutation
{
    private readonly Func<CancellationToken, Task<RecoveryResult>> _lookup;
    private readonly object _gate = new();
    private MutationState _state;

    internal Mutation(string key, MutationState state, Func<CancellationToken, Task<RecoveryResult>> lookup)
    {
        IdempotencyKey = key; _state = state; _lookup = lookup;
    }

    public string IdempotencyKey { get; }
    public MutationState State { get { lock (_gate) return _state; } }

    /// <summary>The business result, or throws the original error.</summary>
    public JsonElement Result()
    {
        var state = State;
        if (state.Status is MutationStatus.Completed or MutationStatus.Committed or MutationStatus.Accepted) return state.Data ?? default;
        throw state.Error ?? new ApiException("PROTOCOL_ERROR", "The operation has no result");
    }

    /// <summary>Queries the stored receipt of an Unknown write without executing it again.</summary>
    public async Task<MutationState> RecoverAsync(CancellationToken cancellation = default)
    {
        if (State.Status != MutationStatus.Unknown) return State;
        var found = await _lookup(cancellation).ConfigureAwait(false);
        lock (_gate)
        {
            if (_state.Status == MutationStatus.Unknown && found.Status != MutationStatus.Unknown)
                _state = new MutationState(found.Status, found.Data);
            return _state;
        }
    }
}

/// <summary>Bound to one project and one user; safe for concurrent use.</summary>
public sealed class FyrletClient : IDisposable
{
    /// <summary>Consecutive retryable join failures of one subscription before it is reported as failed.</summary>
    private const int MaxJoinRetries = 10;
    private static readonly Regex CapabilityName = new("^[a-z][a-z0-9_.-]*$", RegexOptions.Compiled);

    private readonly FyrletOptions _options;
    private readonly string _endpoint;
    private readonly HttpClient _http;
    private readonly Channel<Action> _events = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    private readonly object _gate = new(); // a Monitor is reentrant, so callbacks may call back into the client
    private readonly Dictionary<string, Entry> _entries = new();
    private Connection? _connection;
    private (string Project, string Subject)? _identity;
    private string? _token;
    private Task<string>? _flight;
    private int _epoch;
    private int _connectingEpoch = -1;
    private int _retries;
    private Timer? _retryTimer;
    private bool _closed;

    public FyrletClient(FyrletOptions options)
    {
        if (string.IsNullOrEmpty(options.ProjectId)) throw new ArgumentException("ProjectId is required");
        foreach (var (name, version) in options.Capabilities ?? new Dictionary<string, int>())
            if (!CapabilityName.IsMatch(name) || version < 1) throw new ArgumentException("capabilities must be names with a positive integer version");
        _options = options;
        _endpoint = Http.EndpointUrl(options.Endpoint);
        _http = options.HttpClient ?? Http.NewClient();
        _ = Task.Run(DrainAsync);
    }

    internal T Locked<T>(Func<T> body) { lock (_gate) return body(); }

    // ---- operations -----------------------------------------------------------------------------

    /// <summary>
    /// Runs an operation and returns its business result. The SDK generates an idempotency key. After a network
    /// interruption the outcome of a write is unknown and <see cref="OutcomeUnknownException"/> carries the key for
    /// <see cref="RecoverAsync"/>. Reuse that key explicitly if you decide to submit the write again.
    /// </summary>
    public async Task<JsonElement> CallAsync(string name, object? input = null, CallOptions? options = null, CancellationToken cancellation = default) =>
        (await MutateAsync(name, input, options, cancellation).ConfigureAwait(false)).Result();

    /// <summary>Like <see cref="CallAsync(string, object?, CallOptions?, CancellationToken)"/>, deserializing the result.</summary>
    public async Task<T?> CallAsync<T>(string name, object? input = null, CallOptions? options = null, CancellationToken cancellation = default) =>
        (await CallAsync(name, input, options, cancellation).ConfigureAwait(false)).Deserialize<T>(FyrletJson.Options);

    /// <summary>Like CallAsync but never throws for a failed operation: inspect <see cref="Mutation.State"/>.</summary>
    public async Task<Mutation> MutateAsync(string name, object? input = null, CallOptions? options = null, CancellationToken cancellation = default)
    {
        var key = options?.IdempotencyKey ?? _options.NewId();
        var body = new Dictionary<string, object?> { ["input"] = input ?? new { } };
        Func<CancellationToken, Task<RecoveryResult>> lookup = token => RecoverReceiptAsync(name, body, key, token);
        lock (_gate) { if (_closed) return new Mutation(key, new MutationState(MutationStatus.Failed, Error: ClosedError()), lookup); }
        var sent = false;
        try
        {
            var envelope = await ExecuteAsync(async (token, ct) =>
            {
                sent = true;
                try { return await RequestAsync(HttpMethod.Post, OperationPath(name), token, body, key, ct).ConfigureAwait(false); }
                catch (ApiException error) when (error.Status is >= 400 and < 500 && error.Code is not ("PROTOCOL_ERROR" or "HTTP_ERROR"))
                {
                    sent = false; // a definite rejection: nothing was written
                    throw;
                }
            }, cancellation).ConfigureAwait(false);
            if (!Enum.TryParse<MutationStatus>(envelope.Outcome, true, out var status) ||
                status is not (MutationStatus.Completed or MutationStatus.Committed or MutationStatus.Accepted))
                throw new ApiException("PROTOCOL_ERROR", "Invalid operation outcome");
            return new Mutation(key, new MutationState(status, envelope.Data), lookup);
        }
        catch (Exception error)
        {
            Exception final = sent ? new OutcomeUnknownException(name, key, error) : error;
            return new Mutation(key, new MutationState(sent ? MutationStatus.Unknown : MutationStatus.Failed, Error: final), lookup);
        }
    }

    /// <summary>Looks up the stored receipt of a write without executing it.</summary>
    public Task<RecoveryResult> RecoverAsync(string name, object? input, string idempotencyKey, CancellationToken cancellation = default)
    {
        lock (_gate) { if (_closed) throw ClosedError(); }
        return RecoverReceiptAsync(name, new Dictionary<string, object?> { ["input"] = input ?? new { } }, idempotencyKey, cancellation);
    }

    /// <summary>The business contract this server exports.</summary>
    public async Task<JsonElement> ContractAsync(CancellationToken cancellation = default) =>
        (await ExecuteAsync((token, ct) => RequestAsync(HttpMethod.Get, "/api/v1/contract", token, null, null, ct), cancellation).ConfigureAwait(false)).Data;

    private static string OperationPath(string name) => "/api/v1/operations/" + Uri.EscapeDataString(name);

    private async Task<RecoveryResult> RecoverReceiptAsync(string name, object body, string key, CancellationToken cancellation)
    {
        var envelope = await ExecuteAsync((token, ct) => RequestAsync(HttpMethod.Post, OperationPath(name) + "/recover", token, body, key, ct), cancellation).ConfigureAwait(false);
        return envelope.Outcome switch
        {
            "unknown" when envelope.Data.ValueKind == JsonValueKind.Null => new RecoveryResult(MutationStatus.Unknown),
            "committed" => new RecoveryResult(MutationStatus.Committed, envelope.Data),
            "accepted" => new RecoveryResult(MutationStatus.Accepted, envelope.Data),
            _ => throw new ApiException("PROTOCOL_ERROR", "Invalid recovery outcome"),
        };
    }

    private Task<Envelope> RequestAsync(HttpMethod method, string path, string token, object? body, string? key, CancellationToken cancellation)
    {
        var headers = new Dictionary<string, string> { ["authorization"] = "Bearer " + token, ["x-project-id"] = _options.ProjectId };
        if (key is not null) headers["idempotency-key"] = key;
        if (_options.Capabilities is { Count: > 0 } capabilities)
            headers["x-fyrlet-capabilities"] = string.Join(", ", capabilities.OrderBy(p => p.Key).Select(p => $"{p.Key}={p.Value}"));
        return Http.SendAsync(_http, method, _endpoint + path, headers, body, _options.Timeout, cancellation);
    }

    /// <summary>Authorizes, runs <paramref name="perform"/> and refreshes the token at most once after an authentication failure.</summary>
    private async Task<Envelope> ExecuteAsync(Func<string, CancellationToken, Task<Envelope>> perform, CancellationToken cancellation)
    {
        try
        {
            var token = await AuthorizeAsync(false, null, cancellation).ConfigureAwait(false);
            try { return await perform(token, cancellation).ConfigureAwait(false); }
            catch (ApiException error) when (error.Status == 401 || error.Code == "UNAUTHENTICATED")
            {
                lock (_gate) { if (_closed) throw ClosedError(); }
                return await perform(await AuthorizeAsync(true, token, cancellation).ConfigureAwait(false), cancellation).ConfigureAwait(false);
            }
        }
        catch (ApiException error) when (error.Code is "UNAUTHENTICATED" or "FORBIDDEN")
        {
            FailAll(error);
            throw;
        }
    }

    private async Task<string> AuthorizeAsync(bool force, string? stale, CancellationToken cancellation)
    {
        while (true)
        {
            string? ready = null;
            Task<string>? wait = null, run = null;
            lock (_gate)
            {
                if (_closed) throw ClosedError();
                // Another caller may already have refreshed past the token this one failed with.
                if (_token is { } token && (!force || (stale is not null && token != stale))) ready = token;
                else if (_flight is { } running) wait = running;
                else run = _flight = Task.Run(() => RefreshTokenAsync(force, cancellation), CancellationToken.None);
            }
            if (ready is not null) return ready;
            if (wait is not null)
            {
                try { await wait.ConfigureAwait(false); } catch (Exception) { /* re-evaluate below */ }
                continue;
            }
            try { return await run!.ConfigureAwait(false); }
            finally { lock (_gate) { if (_flight == run) _flight = null; } }
        }
    }

    private async Task<string> RefreshTokenAsync(bool force, CancellationToken cancellation)
    {
        var fresh = await UserTokenAsync(force, cancellation).ConfigureAwait(false);
        (string Project, string Subject) found;
        try { found = await IdentityAsync(fresh, cancellation).ConfigureAwait(false); }
        catch (ApiException error) when (!force && error.Status == 401)
        {
            fresh = await UserTokenAsync(true, cancellation).ConfigureAwait(false);
            found = await IdentityAsync(fresh, cancellation).ConfigureAwait(false);
        }
        lock (_gate)
        {
            if (_closed) throw ClosedError();
            if (found.Project != _options.ProjectId || (_identity is { } known && found.Subject != known.Subject))
                throw new ApiException("FORBIDDEN", "Create a new client when changing accounts");
            _identity = found;
            _token = fresh;
            return fresh;
        }
    }

    private async Task<string> UserTokenAsync(bool force, CancellationToken cancellation)
    {
        var token = await _options.GetToken(force, cancellation).ConfigureAwait(false);
        lock (_gate) { if (_closed) throw ClosedError(); }
        if (token is null || !token.StartsWith("rts_", StringComparison.Ordinal))
            throw new ApiException("UNAUTHENTICATED", "GetToken must return a user session token");
        return token;
    }

    private async Task<(string Project, string Subject)> IdentityAsync(string token, CancellationToken cancellation)
    {
        var data = (await RequestAsync(HttpMethod.Get, "/api/v1/identity", token, null, null, cancellation).ConfigureAwait(false)).Data;
        if (data.ValueKind == JsonValueKind.Object && data.TryGetProperty("project_id", out var project) && project.ValueKind == JsonValueKind.String &&
            data.TryGetProperty("subject_id", out var subject) && subject.ValueKind == JsonValueKind.String)
            return (project.GetString()!, subject.GetString()!);
        throw new ApiException("PROTOCOL_ERROR", "Invalid identity response");
    }

    private static ApiException ClosedError() => new("CLIENT_CLOSED", "The client is closed");

    // ---- subscriptions --------------------------------------------------------------------------

    /// <summary>Starts a realtime subscription. Observe it with <see cref="Subscription.OnChange"/>.</summary>
    public Subscription Subscribe(string name, object? parameters = null)
    {
        lock (_gate)
        {
            if (_closed) throw ClosedError();
            var id = _options.NewId();
            if (_entries.ContainsKey(id)) throw new InvalidOperationException("NewId returned a duplicate subscription ID");
            var entry = new Entry(id, name, parameters ?? new { }, _options.Delta);
            _entries[id] = entry;
            if (_connection is { } connection) Attach(entry, connection, _epoch); else Start(false);
            return new Subscription(this, entry);
        }
    }

    internal IDisposable AddListener(Entry entry, Action<SubscriptionState> listener)
    {
        lock (_gate)
        {
            var id = entry.NextListener++;
            entry.Listeners[id] = listener;
            Dispatch(listener, entry.State);
            return new Removal(() => { lock (_gate) entry.Listeners.Remove(id); });
        }
    }

    private sealed class Removal(Action remove) : IDisposable { public void Dispose() => remove(); }

    internal async Task RefreshAsync(Entry entry, CancellationToken cancellation)
    {
        Connection? connection;
        lock (_gate) connection = entry.State.Status == SubscriptionStatus.Ready ? entry.Connection : null;
        if (connection is null) throw new ApiException("NOT_READY", "The subscription is not ready");
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sent = connection.Push(entry.Topic, "refresh", new { }, (status, response) =>
        {
            if (status == "ok") done.TrySetResult();
            else if (status == "error") done.TrySetException(ApiException.Channel(response));
            else done.TrySetException(new ApiException("TIMEOUT", "refresh was not acknowledged", retryable: true));
        });
        if (!sent) throw ApiException.Network("The connection was interrupted");
        await done.Task.WaitAsync(cancellation).ConfigureAwait(false);
    }

    internal void Unsubscribe(Entry entry)
    {
        lock (_gate)
        {
            if (!_entries.Remove(entry.Id)) return;
            CancelRejoin(entry);
            entry.Connection?.Leave(entry.Topic);
            entry.Connection = null;
            entry.State = new SubscriptionState(SubscriptionStatus.Closed, null, null, entry.State.Generation, entry.State.Seq);
            Emit(entry);
            entry.Listeners = new();
            if (_entries.Count == 0) Detach();
        }
    }

    /// <summary>Explicitly rebuilds the connection and the retained subscriptions.</summary>
    public async Task ReconnectAsync(CancellationToken cancellation = default)
    {
        int epoch;
        lock (_gate)
        {
            if (_closed) throw ClosedError();
            Detach();
            Recovering();
            if (_entries.Count == 0) return;
            epoch = _epoch;
        }
        try { await ConnectAsync(true, epoch, cancellation).ConfigureAwait(false); }
        catch (Exception error)
        {
            lock (_gate) ConnectionFailed(error, epoch);
            throw;
        }
    }

    /// <summary>Releases subscriptions, timers and connections. The client cannot be reused.</summary>
    public void Dispose()
    {
        lock (_gate)
        {
            if (_closed) return;
            _closed = true;
            Detach();
            foreach (var entry in _entries.Values)
            {
                entry.State = new SubscriptionState(SubscriptionStatus.Closed);
                Emit(entry);
                entry.Listeners = new();
            }
            _entries.Clear();
            _token = null;
        }
        _events.Writer.TryComplete();
    }

    // ---- connection management (callers hold the gate unless noted) -----------------------------

    private void Start(bool force)
    {
        var epoch = _epoch;
        if (_connectingEpoch == epoch) return;
        _connectingEpoch = epoch;
        _ = Task.Run(async () =>
        {
            try { await ConnectAsync(force, epoch, CancellationToken.None).ConfigureAwait(false); }
            catch (Exception error) { lock (_gate) ConnectionFailed(error, epoch); }
        });
    }

    /// <summary>Runs without the gate held.</summary>
    private async Task ConnectAsync(bool force, int epoch, CancellationToken cancellation)
    {
        try
        {
            var token = await AuthorizeAsync(force, null, cancellation).ConfigureAwait(false);
            lock (_gate) { if (_closed || _epoch != epoch || _entries.Count == 0 || _connection is not null) return; }
            var opened = await Connection.OpenAsync(_endpoint, _options.ProjectId, token, _options.Timeout, OnFrame, OnClose, cancellation).ConfigureAwait(false);
            lock (_gate)
            {
                if (_closed || _epoch != epoch || _entries.Count == 0) { opened.Close(); return; }
                _connection = opened;
                foreach (var entry in _entries.Values.ToList())
                    if (entry.State.Status != SubscriptionStatus.Error) Attach(entry, opened, epoch);
            }
        }
        finally
        {
            lock (_gate) { if (_connectingEpoch == epoch) _connectingEpoch = -1; }
        }
    }

    private object JoinPayload(Entry entry)
    {
        var payload = new Dictionary<string, object> { ["protocol_version"] = 1, ["name"] = entry.Name, ["params"] = entry.Params };
        if (_options.Capabilities is { Count: > 0 } capabilities) payload["capabilities"] = capabilities;
        if (entry.WantDelta) payload["delivery"] = "delta-v1";
        return payload;
    }

    private bool IsCurrent(Entry entry, Connection connection, int epoch) =>
        !_closed && _epoch == epoch && entry.Connection == connection && _entries.ContainsKey(entry.Id);

    private void Attach(Entry entry, Connection connection, int epoch)
    {
        entry.Connection = connection;
        connection.Join(entry.Topic, JoinPayload(entry), (status, response) =>
        {
            lock (_gate)
            {
                if (!IsCurrent(entry, connection, epoch)) return;
                if (status == "ok")
                {
                    _retries = 0;
                    entry.JoinFailures = 0;
                    Receive(entry, connection, () => entry.ApplySnapshot(response, _identity, true));
                }
                else if (status != "error") TransportFailed(connection);
                else
                {
                    var error = ApiException.Channel(response);
                    if (error.Code == "UNAUTHENTICATED") TransportFailed(connection);
                    else if (error.Retryable && entry.JoinFailures < MaxJoinRetries)
                    {
                        // For example the observer was briefly unavailable: retry this subscription only.
                        entry.JoinFailures++;
                        entry.State = entry.State with { Status = SubscriptionStatus.Recovering, Error = null };
                        Emit(entry);
                        ScheduleRejoin(entry, connection, epoch);
                    }
                    else Fail(entry, error);
                }
            }
        });
    }

    private void ScheduleRejoin(Entry entry, Connection connection, int epoch)
    {
        CancelRejoin(entry);
        entry.Rejoin = new Timer(_ =>
        {
            lock (_gate)
            {
                entry.Rejoin = null;
                if (IsCurrent(entry, connection, epoch)) Attach(entry, connection, epoch);
            }
        }, null, Delay(entry.JoinFailures), System.Threading.Timeout.InfiniteTimeSpan);
    }

    private static void CancelRejoin(Entry entry)
    {
        entry.Rejoin?.Dispose();
        entry.Rejoin = null;
    }

    private TimeSpan Delay(int attempt) =>
        _options.RetryDelay?.Invoke(attempt) ?? TimeSpan.FromSeconds(Math.Min(0.25 * Math.Pow(2, Math.Min(Math.Max(attempt - 1, 0), 7)), 30));

    private void OnFrame(Connection connection, Frame frame)
    {
        lock (_gate)
        {
            if (connection != _connection || _closed || !frame.Topic.StartsWith("subscription:", StringComparison.Ordinal)) return;
            if (!_entries.TryGetValue(frame.Topic["subscription:".Length..], out var entry) || entry.Connection != connection) return;
            switch (frame.Event)
            {
                case "snapshot": Receive(entry, connection, () => entry.ApplySnapshot(frame.Payload, _identity, false)); break;
                case "delta": Receive(entry, connection, () => entry.ApplyDelta(frame.Payload)); break;
                case "status":
                    var error = ApiException.Channel(frame.Payload);
                    if (error.Code == "UNAUTHENTICATED")
                    {
                        foreach (var item in _entries.Values) item.State = item.State with { Data = null };
                        TransportFailed(connection);
                    }
                    else if (error.Retryable) TransportFailed(connection);
                    else Fail(entry, error);
                    break;
                case "phx_error": TransportFailed(connection); break;
                case "phx_close": Fail(entry, new ApiException("SUBSCRIPTION_CLOSED", "The server closed the subscription")); break;
            }
        }
    }

    private void OnClose(Connection connection, ApiException? failure)
    {
        lock (_gate)
        {
            if (connection != _connection || _closed) return;
            if (failure is { Retryable: false }) FailAllLocked(failure); else TransportFailed(connection);
        }
    }

    private void Receive(Entry entry, Connection connection, Func<Applied> change)
    {
        var before = entry.State;
        Applied result;
        try { result = change(); }
        catch (ApiException error) { Fail(entry, error); return; }
        if (entry.State.Seq != before.Seq || entry.State.Status != before.Status || entry.State.Generation != before.Generation) Emit(entry);
        switch (result)
        {
            case Applied.Reconnect: TransportFailed(connection); break;
            case Applied.Ack ack: connection.Notify(entry.Topic, "ack", new Dictionary<string, object> { ["g"] = ack.Generation, ["s"] = ack.Seq }); break;
        }
    }

    private void TransportFailed(Connection connection)
    {
        if (connection != _connection || _closed) return;
        Detach();
        Recovering();
        ScheduleRetry();
    }

    private void ConnectionFailed(Exception error, int epoch)
    {
        if (_closed || _epoch != epoch || error is OperationCanceledException) return;
        // A foreign error, such as a failing GetToken, counts as a retryable network failure.
        var failure = ApiException.From(error);
        if (!failure.Retryable) FailAllLocked(failure); else { Recovering(); ScheduleRetry(); }
    }

    private void ScheduleRetry()
    {
        if (_closed || _retryTimer is not null || _entries.Count == 0) return;
        _retries++;
        _retryTimer = new Timer(_ =>
        {
            lock (_gate)
            {
                _retryTimer = null;
                if (!_closed && _entries.Count > 0) Start(true);
            }
        }, null, Delay(_retries), System.Threading.Timeout.InfiniteTimeSpan);
    }

    private void Recovering()
    {
        foreach (var entry in _entries.Values)
        {
            if (entry.State.Status == SubscriptionStatus.Error) continue;
            entry.State = entry.State with { Status = SubscriptionStatus.Recovering, Error = null };
            Emit(entry);
        }
    }

    private void FailAll(ApiException error) { lock (_gate) FailAllLocked(error); }

    private void FailAllLocked(ApiException error)
    {
        Detach();
        _token = null;
        foreach (var entry in _entries.Values.ToList()) Fail(entry, error);
    }

    private void Fail(Entry entry, ApiException error)
    {
        CancelRejoin(entry);
        entry.Connection?.Leave(entry.Topic);
        entry.Connection = null;
        entry.State = entry.State with { Status = SubscriptionStatus.Error, Data = null, Error = error };
        Emit(entry);
    }

    private void Detach()
    {
        _epoch++;
        _connectingEpoch = -1;
        _retryTimer?.Dispose();
        _retryTimer = null;
        var old = _connection;
        _connection = null;
        foreach (var entry in _entries.Values) { CancelRejoin(entry); entry.Connection = null; }
        old?.Close();
    }

    // ---- listener dispatch ----------------------------------------------------------------------

    private void Emit(Entry entry)
    {
        foreach (var listener in entry.Listeners.Values) Dispatch(listener, entry.State);
    }

    private void Dispatch(Action<SubscriptionState> listener, SubscriptionState state) =>
        _events.Writer.TryWrite(() => listener(state));

    private async Task DrainAsync()
    {
        await foreach (var job in _events.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try { job(); }
            catch (Exception error)
            {
                try { _options.OnListenerError?.Invoke(error); } catch (Exception) { /* listeners must not break the client */ }
            }
        }
    }
}

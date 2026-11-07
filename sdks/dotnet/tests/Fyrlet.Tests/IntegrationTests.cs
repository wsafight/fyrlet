using System.Net;
using System.Text.Json;
using Xunit;

namespace Fyrlet.Tests;

// Runs against a real Fyrlet inbox server. Start it with scripts/integration_sdks.sh.

public sealed class IntegrationFactAttribute : FactAttribute
{
    public IntegrationFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("INTEGRATION_ENDPOINT") is null || Environment.GetEnvironmentVariable("INTEGRATION_FIXTURES") is null)
            Skip = "needs INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES";
    }
}

public sealed record Item(string Id, string Text, int Version);
public sealed record Project([property: System.Text.Json.Serialization.JsonPropertyName("project_id")] string ProjectId,
    [property: System.Text.Json.Serialization.JsonPropertyName("service_key")] string ServiceKey);

public sealed class IntegrationTests : IDisposable
{
    private readonly string _endpoint = Environment.GetEnvironmentVariable("INTEGRATION_ENDPOINT") ?? "";
    private readonly List<FyrletClient> _clients = new();
    private readonly List<Project> _projects;

    public IntegrationTests()
    {
        var fixtures = Environment.GetEnvironmentVariable("INTEGRATION_FIXTURES");
        _projects = fixtures is null ? new() : JsonSerializer.Deserialize<List<Project>>(File.ReadAllText(fixtures))!;
    }

    public void Dispose() { foreach (var client in _clients) client.Dispose(); }

    private SessionService Service(int project = 0) => new(_endpoint, _projects[project].ServiceKey);

    private async Task<FyrletClient> UserAsync(int project = 0, string? subject = null, HttpClient? http = null)
    {
        var session = await Service(project).IssueSessionAsync(subject ?? Guid.NewGuid().ToString(), ttlSeconds: 600);
        var client = new FyrletClient(new FyrletOptions
        {
            Endpoint = _endpoint, ProjectId = _projects[project].ProjectId, GetToken = (_, _) => Task.FromResult(session.Token),
            RetryDelay = _ => TimeSpan.FromMilliseconds(50), HttpClient = http,
        });
        _clients.Add(client);
        return client;
    }

    private static async Task Until(string what, Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline) { if (condition()) return; await Task.Delay(20); }
        throw new Xunit.Sdk.XunitException("condition not reached: " + what);
    }

    private static Task Ready(Subscription sub) => Until("ready", () => sub.State.Status == SubscriptionStatus.Ready);
    private static Item[] Items(Subscription sub) => sub.State.Decode<Item[]>() ?? Array.Empty<Item>();

    [IntegrationFact]
    public async Task CallIdempotencyConflictAndContract()
    {
        var client = await UserAsync();
        var key = Guid.NewGuid().ToString();
        var first = (await client.CallAsync<Item>("inbox.add", new { text = "hello" }, new CallOptions { IdempotencyKey = key }))!;
        var again = (await client.CallAsync<Item>("inbox.add", new { text = "hello" }, new CallOptions { IdempotencyKey = key }))!;
        Assert.Equal(first.Id, again.Id);
        var conflict = await Assert.ThrowsAsync<ApiException>(() => client.CallAsync("inbox.add", new { text = "changed" }, new CallOptions { IdempotencyKey = key }));
        Assert.Equal(("CONFLICT", 409), (conflict.Code, conflict.Status));
        Assert.Equal(1, (await client.CallAsync("inbox.history", new { })).GetProperty("items").GetArrayLength());
        await client.CallAsync("inbox.update", new { id = first.Id, text = "new", expected_version = first.Version });
        var stale = await Assert.ThrowsAsync<ApiException>(() => client.CallAsync("inbox.update", new { id = first.Id, text = "late", expected_version = first.Version }));
        Assert.Equal("CONFLICT", stale.Code);
        Assert.Contains("inbox.add", (await client.ContractAsync()).GetRawText());
    }

    [IntegrationFact]
    public async Task ConcurrentDuplicateCallsShareOneWrite()
    {
        var client = await UserAsync();
        var key = Guid.NewGuid().ToString();
        var results = await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => client.CallAsync<Item>("inbox.add", new { text = "c" }, new CallOptions { IdempotencyKey = key })));
        Assert.Single(results.Select(r => r!.Id).Distinct());
    }

    [IntegrationFact]
    public async Task SubscriptionSnapshotDeltaRefreshAndSharedDevices()
    {
        var subject = Guid.NewGuid().ToString();
        var first = await UserAsync(subject: subject);
        var second = await UserAsync(subject: subject);
        var left = first.Subscribe("inbox.recent");
        var right = second.Subscribe("inbox.recent");
        await Ready(left); await Ready(right);
        var seen = new List<SubscriptionStatus>();
        left.OnChange(state => { lock (seen) seen.Add(state.Status); });
        var created = (await first.CallAsync<Item>("inbox.add", new { text = "shared" }))!;
        await Until("left sees item", () => Items(left).Any(i => i.Id == created.Id));
        await Until("right sees item", () => Items(right).Any(i => i.Id == created.Id));
        await first.CallAsync("inbox.update", new { id = created.Id, text = "edited", expected_version = created.Version });
        await Until("delta applied", () => Items(left).FirstOrDefault()?.Text == "edited");
        var before = left.State.Seq;
        await left.RefreshAsync();
        await Until("refresh snapshot", () => left.State.Seq > before);
        lock (seen) Assert.Equal(SubscriptionStatus.Ready, seen[0]);
        left.Unsubscribe();
        Assert.Equal(SubscriptionStatus.Closed, left.State.Status);
        Assert.Null(left.State.Data);
        Assert.Equal("NOT_READY", (await Assert.ThrowsAsync<ApiException>(() => left.RefreshAsync())).Code);
    }

    [IntegrationFact]
    public async Task AuthorizationIsolation()
    {
        var owner = await UserAsync();
        await owner.CallAsync("inbox.add", new { text = "private" });
        foreach (var other in new[] { await UserAsync(), await UserAsync(project: 1) })
        {
            var sub = other.Subscribe("inbox.recent");
            await Ready(sub);
            Assert.Empty(Items(sub));
            Assert.Equal(0, (await other.CallAsync("inbox.history", new { })).GetProperty("items").GetArrayLength());
        }
    }

    private sealed class LossyHandler : DelegatingHandler
    {
        public int Writes;
        public LossyHandler() : base(new SocketsHttpHandler { AllowAutoRedirect = false }) { }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            var response = await base.SendAsync(request, cancellation);
            if (request.RequestUri!.AbsolutePath.EndsWith("/operations/inbox.add"))
            {
                Interlocked.Increment(ref Writes);
                response.Dispose();
                throw new HttpRequestException("injected response loss after commit");
            }
            return response;
        }
    }

    [IntegrationFact]
    public async Task LostResponseIsUnknownThenRecoveredWithoutSecondWrite()
    {
        var handler = new LossyHandler();
        var client = await UserAsync(http: new HttpClient(handler));
        var mutation = await client.MutateAsync("inbox.add", new { text = "lost" });
        Assert.Equal(MutationStatus.Unknown, mutation.State.Status);
        Assert.IsType<OutcomeUnknownException>(mutation.State.Error);
        Assert.Throws<OutcomeUnknownException>(() => mutation.Result());
        var recovered = await mutation.RecoverAsync();
        Assert.Equal(MutationStatus.Committed, recovered.Status);
        Assert.Equal("lost", recovered.Data!.Value.GetProperty("text").GetString());
        Assert.Equal(1, handler.Writes);
        var stranger = await UserAsync();
        Assert.Equal(MutationStatus.Unknown, (await stranger.RecoverAsync("inbox.add", new { text = "lost" }, mutation.IdempotencyKey)).Status);
    }

    [IntegrationFact]
    public async Task TokenRefreshAndRevocation()
    {
        var service = Service();
        var subject = Guid.NewGuid().ToString();
        var old = await service.IssueSessionAsync(subject);
        await service.RevokeSessionAsync(old.SessionId);
        var calls = new List<bool>();
        var client = new FyrletClient(new FyrletOptions
        {
            Endpoint = _endpoint, ProjectId = _projects[0].ProjectId,
            GetToken = async (force, ct) => { lock (calls) calls.Add(force); return force ? (await service.IssueSessionAsync(subject, cancellation: ct)).Token : old.Token; },
        });
        _clients.Add(client);
        await client.CallAsync("inbox.history", new { });
        Assert.Equal(new[] { false, true }, calls);

        var live = await service.IssueSessionAsync(subject);
        var dead = new FyrletClient(new FyrletOptions
        {
            Endpoint = _endpoint, ProjectId = _projects[0].ProjectId, RetryDelay = _ => TimeSpan.FromMilliseconds(50),
            GetToken = (force, _) => force ? throw new ApiException("UNAUTHENTICATED", "logged out") : Task.FromResult(live.Token),
        });
        _clients.Add(dead);
        var sub = dead.Subscribe("inbox.recent");
        await Ready(sub);
        await service.RevokeSessionAsync(live.SessionId);
        await Until("terminal error", () => sub.State.Status == SubscriptionStatus.Error);
        Assert.Null(sub.State.Data);
        Assert.Equal("UNAUTHENTICATED", sub.State.Error!.Code);
    }

    [IntegrationFact]
    public async Task AccountSwitchIsRejected()
    {
        var service = Service();
        var a = await service.IssueSessionAsync(Guid.NewGuid().ToString());
        var b = await service.IssueSessionAsync(Guid.NewGuid().ToString());
        var client = new FyrletClient(new FyrletOptions
        {
            Endpoint = _endpoint, ProjectId = _projects[0].ProjectId, GetToken = (force, _) => Task.FromResult(force ? b.Token : a.Token),
        });
        _clients.Add(client);
        await client.CallAsync("inbox.history", new { });
        await service.RevokeSessionAsync(a.SessionId); // the refresh now yields B's identity
        Assert.Equal("FORBIDDEN", (await Assert.ThrowsAsync<ApiException>(() => client.CallAsync("inbox.history", new { }))).Code);
    }

    [IntegrationFact]
    public async Task RecoversAfterReconnectAndCloseReleases()
    {
        var client = await UserAsync();
        var sub = client.Subscribe("inbox.recent");
        await Ready(sub);
        var created = (await client.CallAsync<Item>("inbox.add", new { text = "before" }))!;
        await Until("item arrives", () => Items(sub).Length == 1);
        var statuses = new List<SubscriptionStatus>();
        sub.OnChange(state => { lock (statuses) statuses.Add(state.Status); });
        var generation = sub.State.Generation;
        await client.ReconnectAsync();
        await Ready(sub);
        await Until("new generation", () => sub.State.Generation != generation);
        lock (statuses) Assert.Contains(SubscriptionStatus.Recovering, statuses);
        Assert.Equal(new[] { created.Id }, Items(sub).Select(i => i.Id));
        client.Dispose();
        Assert.Equal(SubscriptionStatus.Closed, sub.State.Status);
        Assert.Equal("CLIENT_CLOSED", (await Assert.ThrowsAsync<ApiException>(() => client.CallAsync("inbox.history", new { }))).Code);
        Assert.Throws<ApiException>(() => client.Subscribe("inbox.recent"));
    }

    [IntegrationFact]
    public async Task ListenerExceptionsDoNotBreakTheClient()
    {
        var errors = new List<Exception>();
        var session = await Service().IssueSessionAsync(Guid.NewGuid().ToString());
        var client = new FyrletClient(new FyrletOptions
        {
            Endpoint = _endpoint, ProjectId = _projects[0].ProjectId, GetToken = (_, _) => Task.FromResult(session.Token),
            OnListenerError = error => { lock (errors) errors.Add(error); },
        });
        _clients.Add(client);
        var sub = client.Subscribe("inbox.recent");
        sub.OnChange(_ => throw new InvalidOperationException("boom"));
        await Ready(sub);
        await Until("listener error reported", () => { lock (errors) return errors.Count > 0; });
    }
}

using System.Text.Json;
using Xunit;

namespace Fyrlet.Tests;

public class UnitTests
{
    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement;
    private static string[] Ids(JsonElement? view) => view!.Value.EnumerateArray().Select(e => e.GetProperty("id").GetString()!).ToArray();

    [Fact]
    public void DeltaChangesAndClearsWithoutMutatingInput()
    {
        var view = Json("""[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]""");
        var result = Delta.Apply(view, Json("""{"c":[["a",{"text":"z"},["note"]]]}"""))!.Value;
        Assert.Equal("z", result[0].GetProperty("text").GetString());
        Assert.False(result[0].TryGetProperty("note", out _));
        Assert.Equal("n", view[0].GetProperty("note").GetString());
    }

    [Fact]
    public void DeltaNullIsNotDeletion()
    {
        var result = Delta.Apply(Json("""[{"id":"a","t":1}]"""), Json("""{"c":[["a",{"t":null}]]}"""))!.Value;
        Assert.Equal(JsonValueKind.Null, result[0].GetProperty("t").ValueKind);
    }

    [Fact]
    public void DeltaAddRemoveReorder() =>
        Assert.Equal(new[] { "c", "b" }, Ids(Delta.Apply(Json("""[{"id":"a"},{"id":"b"}]"""), Json("""{"r":["a"],"a":[{"id":"c"}],"o":["c","b"]}"""))));

    [Theory]
    [InlineData("""{"x":[]}""")]
    [InlineData("""{"r":["missing"],"o":["a"]}""")]
    [InlineData("""{"a":[{"id":"a"}],"o":["a"]}""")]
    [InlineData("""{"c":[["a",{"id":"a"}]]}""")]
    [InlineData("""{"c":[["a",{"t":1},["t"]]]}""")]
    [InlineData("""{"c":[["a",{"t":1}],["a",{"t":2}]]}""")]
    [InlineData("""{"r":["a"]}""")]
    [InlineData("""{"c":[["zzz",{"t":1}]]}""")]
    public void DeltaRejectsInvalidPatches(string patch) =>
        Assert.Null(Delta.Apply(Json("""[{"id":"a","t":0}]"""), Json(patch)));

    [Fact]
    public void DecodeFrames()
    {
        const string frame = """[null,"1","t","e",{}]""";
        Assert.Single(Wire.Decode(frame)!);
        Assert.Equal(2, Wire.Decode($$"""{"batch":[{{frame}},{{frame}}]}""")!.Count);
        var many = string.Join(",", Enumerable.Repeat(frame, 65));
        foreach (var bad in new[] { "[]", """{"batch":[]}""", $$"""{"batch":[{{many}}]}""", $$"""{"batch":[{{frame}}],"x":1}""", "[1,2]", """[null,null,"t","e",[]]""", "nope" })
            Assert.Null(Wire.Decode(bad));
    }

    [Fact]
    public void SocketUrlAndAuthProtocol()
    {
        Assert.Equal("wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0", Wire.SocketUrl("https://x.test", "p1").AbsoluteUri);
        Assert.Equal("base64url.bearer.phx.cnRzX2FiYw", Wire.AuthProtocol("rts_abc"));
    }

    [Fact]
    public void EndpointValidation()
    {
        Assert.Equal("http://localhost:4000", Http.EndpointUrl("http://localhost:4000/"));
        foreach (var bad in new[] { "ftp://x", "http://u:p@x", "http://x?a=1", "http://x#f", "nope" })
            Assert.Throws<ArgumentException>(() => Http.EndpointUrl(bad));
    }

    [Fact]
    public void Errors()
    {
        var error = ApiException.Channel(Json("""{"error":{"code":"CONFLICT","message":"m"},"status":409}"""));
        Assert.Equal(("CONFLICT", 409), (error.Code, error.Status));
        Assert.Equal("PROTOCOL_ERROR", ApiException.Channel(Json("{}")).Code);
        var unknown = new OutcomeUnknownException("op", "key", new ApiException("TIMEOUT", "t", retryable: true));
        Assert.Equal(("TIMEOUT", false, "key"), (unknown.Code, unknown.Retryable, unknown.IdempotencyKey));
    }

    private static JsonElement Snapshot(string overrides = "{}")
    {
        var map = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>("""{"protocol_version":1,"subscription_id":"s","project_id":"p","subject_id":"u","generation":"g1","seq":1,"data":[{"id":"a"}],"delivery":"delta-v1"}""")!;
        foreach (var (key, value) in JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(overrides)!) map[key] = value;
        return JsonSerializer.SerializeToElement(map);
    }

    private static readonly (string, string) Who = ("p", "u");

    [Fact]
    public void EntrySnapshotAndDeltaFlow()
    {
        var entry = new Entry("s", "n", new { }, true);
        Assert.Equal(new Applied.Ack("g1", 1), entry.ApplySnapshot(Snapshot(), Who, true));
        Assert.Equal(SubscriptionStatus.Ready, entry.State.Status);
        Assert.Equal(new Applied.Ack("g1", 2), entry.ApplyDelta(Json("""{"g":"g1","b":1,"s":2,"p":{"c":[["a",{"t":1}]]}}""")));
        Assert.Equal(2, entry.State.Seq);
        Assert.Equal(new Applied.Ack("g1", 2), entry.ApplyDelta(Json("""{"g":"g1","b":1,"s":2,"p":{}}""")));
        Assert.IsType<Applied.Nothing>(entry.ApplyDelta(Json("""{"g":"old","b":1,"s":2,"p":{}}""")));
        Assert.IsType<Applied.Reconnect>(entry.ApplyDelta(Json("""{"g":"g1","b":3,"s":4,"p":{}}""")));
    }

    [Fact]
    public void EntryRejectsForeignSnapshotsAndUnnegotiatedDeltas()
    {
        foreach (var overrides in new[] { """{"subject_id":"other"}""", """{"subscription_id":"x"}""", """{"seq":0}""", """{"protocol_version":2}""" })
            Assert.Throws<ApiException>(() => new Entry("s", "n", new { }, true).ApplySnapshot(Snapshot(overrides), Who, true));
        var entry = new Entry("s", "n", new { }, true);
        entry.ApplySnapshot(Snapshot("""{"delivery":"snapshot"}"""), Who, true);
        Assert.Throws<ApiException>(() => entry.ApplyDelta(Json("""{"g":"g1","b":1,"s":2,"p":{}}""")));
    }
}

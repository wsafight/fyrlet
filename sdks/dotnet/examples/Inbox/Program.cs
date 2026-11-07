// FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... dotnet run --project examples/Inbox -- "First note"
//
// In a real application the SessionService runs on your backend and only the token reaches the client.
using Fyrlet;

var endpoint = Environment.GetEnvironmentVariable("FYRLET_ENDPOINT")!;
var service = new SessionService(endpoint, Environment.GetEnvironmentVariable("FYRLET_SERVICE_KEY")!);

using var client = new FyrletClient(new FyrletOptions
{
    Endpoint = endpoint,
    ProjectId = Environment.GetEnvironmentVariable("FYRLET_PROJECT_ID")!,
    GetToken = async (forceRefresh, ct) => (await service.IssueSessionAsync("example-user", ttlSeconds: 600, cancellation: ct)).Token,
});

var recent = client.Subscribe("inbox.recent", new { limit = 20 });
recent.OnChange(state => Console.WriteLine($"{state.Status} {string.Join(", ", state.Decode<Item[]>()?.Select(i => i.Text) ?? [])}"));

foreach (var text in args.Length > 0 ? args : ["Hello from C#"])
    await client.CallAsync("inbox.add", new { text });
await Task.Delay(1000); // let the delta arrive before exiting

record Item(string Id, string Text);

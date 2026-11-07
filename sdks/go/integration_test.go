package fyrlet_test

// Runs against a real Fyrlet inbox server. Start it with scripts/integration_sdks.sh.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	fyrlet "github.com/wsafight/fyrlet/sdks/go"
)

type project struct {
	ProjectID  string `json:"project_id"`
	ServiceKey string `json:"service_key"`
}

type item struct {
	ID      string `json:"id"`
	Text    string `json:"text"`
	Version int    `json:"version"`
}

func setup(t *testing.T) (string, []project) {
	t.Helper()
	endpoint, fixtures := os.Getenv("INTEGRATION_ENDPOINT"), os.Getenv("INTEGRATION_FIXTURES")
	if endpoint == "" || fixtures == "" {
		t.Skip("needs INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES")
	}
	raw, err := os.ReadFile(fixtures)
	if err != nil {
		t.Fatal(err)
	}
	var projects []project
	if err := json.Unmarshal(raw, &projects); err != nil {
		t.Fatal(err)
	}
	return endpoint, projects
}

func newID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

type harness struct {
	t        *testing.T
	endpoint string
	projects []project
}

func (h *harness) user(projectIndex int, subject string, mutate func(*fyrlet.Options)) (*fyrlet.Client, *fyrlet.UserSession) {
	h.t.Helper()
	if subject == "" {
		subject = "user-" + newID()
	}
	service, err := fyrlet.NewSessionService(h.endpoint, h.projects[projectIndex].ServiceKey, nil)
	if err != nil {
		h.t.Fatal(err)
	}
	session, err := service.IssueSession(context.Background(), fyrlet.IssueSessionInput{ExternalSubject: subject, TTLSeconds: 600})
	if err != nil {
		h.t.Fatal(err)
	}
	opts := fyrlet.Options{
		Endpoint: h.endpoint, ProjectID: h.projects[projectIndex].ProjectID,
		GetToken:   func(context.Context, bool) (string, error) { return session.Token, nil },
		RetryDelay: func(int) time.Duration { return 50 * time.Millisecond },
	}
	if mutate != nil {
		mutate(&opts)
	}
	client, err := fyrlet.NewClient(opts)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(client.Close)
	return client, session
}

func until(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("condition not reached: %s", what)
}

func ready(t *testing.T, sub *fyrlet.Subscription) {
	t.Helper()
	until(t, "subscription ready", func() bool { return sub.State().Status == fyrlet.StatusReady })
}

func items(sub *fyrlet.Subscription) []item {
	var out []item
	_ = sub.State().Decode(&out)
	return out
}

func apiCode(err error) string {
	var api *fyrlet.APIError
	if errors.As(err, &api) {
		return api.Code
	}
	return ""
}

func TestCallIdempotencyConflictAndContract(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	ctx := context.Background()
	client, _ := h.user(0, "", nil)
	key := "key-" + newID()
	var first item
	if err := client.CallInto(ctx, "inbox.add", map[string]any{"text": "hello"}, &first, fyrlet.WithIdempotencyKey(key)); err != nil {
		t.Fatal(err)
	}
	var again item
	if err := client.CallInto(ctx, "inbox.add", map[string]any{"text": "hello"}, &again, fyrlet.WithIdempotencyKey(key)); err != nil || again.ID != first.ID {
		t.Fatal(again, err)
	}
	_, err := client.Call(ctx, "inbox.add", map[string]any{"text": "changed"}, fyrlet.WithIdempotencyKey(key))
	var api *fyrlet.APIError
	if !errors.As(err, &api) || api.Code != "CONFLICT" || api.Status != 409 {
		t.Fatalf("expected CONFLICT, got %v", err)
	}
	var history struct{ Items []item }
	if err := client.CallInto(ctx, "inbox.history", nil, &history); err != nil || len(history.Items) != 1 {
		t.Fatal(history, err)
	}
	if _, err := client.Call(ctx, "inbox.update", map[string]any{"id": first.ID, "text": "new", "expected_version": first.Version}); err != nil {
		t.Fatal(err)
	}
	_, err = client.Call(ctx, "inbox.update", map[string]any{"id": first.ID, "text": "late", "expected_version": first.Version})
	if apiCode(err) != "CONFLICT" {
		t.Fatalf("expected a version conflict, got %v", err)
	}
	contract, err := client.Contract(ctx)
	if err != nil || !strings.Contains(string(contract), "inbox.add") {
		t.Fatal(err)
	}
}

func TestConcurrentDuplicateCallsShareOneWrite(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	client, _ := h.user(0, "", nil)
	key := "key-" + newID()
	ids := make(chan string, 16)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var created item
			if err := client.CallInto(context.Background(), "inbox.add", map[string]any{"text": "c"}, &created, fyrlet.WithIdempotencyKey(key)); err != nil {
				t.Error(err)
			}
			ids <- created.ID
		}()
	}
	wg.Wait()
	close(ids)
	seen := map[string]bool{}
	for id := range ids {
		seen[id] = true
	}
	if len(seen) != 1 {
		t.Fatalf("expected one record, got %d", len(seen))
	}
}

func TestSubscriptionSnapshotDeltaRefreshAndSharedDevices(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	ctx := context.Background()
	subject := "shared-" + newID()
	first, _ := h.user(0, subject, nil)
	second, _ := h.user(0, subject, nil)
	left, err := first.Subscribe("inbox.recent", nil)
	if err != nil {
		t.Fatal(err)
	}
	right, _ := second.Subscribe("inbox.recent", nil)
	ready(t, left)
	ready(t, right)
	var mu sync.Mutex
	var seen []fyrlet.Status
	left.OnChange(func(s fyrlet.State) { mu.Lock(); seen = append(seen, s.Status); mu.Unlock() })
	var created item
	if err := first.CallInto(ctx, "inbox.add", map[string]any{"text": "shared"}, &created); err != nil {
		t.Fatal(err)
	}
	has := func(sub *fyrlet.Subscription, text string) func() bool {
		return func() bool {
			for _, entry := range items(sub) {
				if entry.ID == created.ID && entry.Text == text {
					return true
				}
			}
			return false
		}
	}
	until(t, "left sees item", has(left, "shared"))
	until(t, "right sees item", has(right, "shared"))
	if _, err := first.Call(ctx, "inbox.update", map[string]any{"id": created.ID, "text": "edited", "expected_version": created.Version}); err != nil {
		t.Fatal(err)
	}
	until(t, "delta applied", has(left, "edited"))
	before := left.State().Seq
	if err := left.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	until(t, "refresh snapshot", func() bool { return left.State().Seq > before })
	mu.Lock()
	if seen[0] != fyrlet.StatusReady {
		t.Fatalf("first emission should be the current state, got %v", seen[0])
	}
	mu.Unlock()
	left.Unsubscribe()
	if s := left.State(); s.Status != fyrlet.StatusClosed || s.Data != nil {
		t.Fatalf("unsubscribed state %+v", s)
	}
	if apiCode(left.Refresh(ctx)) != "NOT_READY" {
		t.Fatal("refresh after unsubscribe should fail")
	}
}

func TestAuthorizationIsolation(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	ctx := context.Background()
	owner, _ := h.user(0, "", nil)
	if _, err := owner.Call(ctx, "inbox.add", map[string]any{"text": "private"}); err != nil {
		t.Fatal(err)
	}
	other, _ := h.user(0, "", nil)
	foreign, _ := h.user(1, "", nil)
	for _, client := range []*fyrlet.Client{other, foreign} {
		sub, _ := client.Subscribe("inbox.recent", nil)
		ready(t, sub)
		if len(items(sub)) != 0 {
			t.Fatal("subscription leaked another user's data")
		}
		var history struct{ Items []item }
		if err := client.CallInto(ctx, "inbox.history", nil, &history); err != nil || len(history.Items) != 0 {
			t.Fatal(history, err)
		}
	}
}

type lossy struct {
	base   http.RoundTripper
	writes int
}

func (l *lossy) RoundTrip(r *http.Request) (*http.Response, error) {
	response, err := l.base.RoundTrip(r)
	if err == nil && strings.HasSuffix(r.URL.Path, "/operations/inbox.add") {
		l.writes++
		response.Body.Close()
		return nil, errors.New("injected response loss after commit")
	}
	return response, err
}

func TestLostResponseIsUnknownThenRecoveredWithoutSecondWrite(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	ctx := context.Background()
	transport := &lossy{base: http.DefaultTransport}
	client, _ := h.user(0, "", func(o *fyrlet.Options) { o.HTTPClient = &http.Client{Transport: transport} })
	mutation := client.Mutate(ctx, "inbox.add", map[string]any{"text": "lost"})
	var unknown *fyrlet.OutcomeUnknownError
	if mutation.State().Status != fyrlet.MutationUnknown || !errors.As(mutation.State().Err, &unknown) {
		t.Fatalf("expected an unknown outcome, got %+v", mutation.State())
	}
	if _, err := mutation.Result(); !errors.As(err, &unknown) {
		t.Fatal("Result should return the unknown error")
	}
	state, err := mutation.Recover(ctx)
	if err != nil || state.Status != fyrlet.MutationCommitted {
		t.Fatal(state, err)
	}
	var recovered item
	if err := json.Unmarshal(state.Data, &recovered); err != nil || recovered.Text != "lost" {
		t.Fatal(recovered, err)
	}
	if transport.writes != 1 {
		t.Fatalf("expected one write, got %d", transport.writes)
	}
	stranger, _ := h.user(0, "", nil)
	found, err := stranger.Recover(ctx, "inbox.add", map[string]any{"text": "lost"}, mutation.IdempotencyKey)
	if err != nil || found.Status != fyrlet.MutationUnknown {
		t.Fatal("another user must not see the receipt", found, err)
	}
}

func TestTokenRefreshAndRevocation(t *testing.T) {
	endpoint, projects := setup(t)
	ctx := context.Background()
	service, _ := fyrlet.NewSessionService(endpoint, projects[0].ServiceKey, nil)
	subject := "refresh-" + newID()
	old, _ := service.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: subject})
	if ok, err := service.RevokeSession(ctx, old.SessionID); err != nil || !ok {
		t.Fatal(ok, err)
	}
	var calls []bool
	client, _ := fyrlet.NewClient(fyrlet.Options{Endpoint: endpoint, ProjectID: projects[0].ProjectID,
		GetToken: func(ctx context.Context, force bool) (string, error) {
			calls = append(calls, force)
			if force {
				fresh, err := service.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: subject})
				return fresh.Token, err
			}
			return old.Token, nil
		}})
	defer client.Close()
	if _, err := client.Call(ctx, "inbox.history", nil); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || calls[0] || !calls[1] {
		t.Fatalf("expected one forced refresh, got %v", calls)
	}

	live, _ := service.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: subject})
	dead, _ := fyrlet.NewClient(fyrlet.Options{Endpoint: endpoint, ProjectID: projects[0].ProjectID,
		RetryDelay: func(int) time.Duration { return 50 * time.Millisecond },
		GetToken: func(_ context.Context, force bool) (string, error) {
			if force {
				return "", &fyrlet.APIError{Code: "UNAUTHENTICATED", Message: "logged out"}
			}
			return live.Token, nil
		}})
	defer dead.Close()
	sub, _ := dead.Subscribe("inbox.recent", nil)
	ready(t, sub)
	if _, err := service.RevokeSession(ctx, live.SessionID); err != nil {
		t.Fatal(err)
	}
	until(t, "terminal error", func() bool { return sub.State().Status == fyrlet.StatusError })
	if s := sub.State(); s.Data != nil || s.Err == nil || s.Err.Code != "UNAUTHENTICATED" {
		t.Fatalf("expected cleared data and UNAUTHENTICATED, got %+v", s)
	}
}

func TestAccountSwitchIsRejected(t *testing.T) {
	endpoint, projects := setup(t)
	ctx := context.Background()
	service, _ := fyrlet.NewSessionService(endpoint, projects[0].ServiceKey, nil)
	a, _ := service.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: "a-" + newID()})
	b, _ := service.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: "b-" + newID()})
	client, _ := fyrlet.NewClient(fyrlet.Options{Endpoint: endpoint, ProjectID: projects[0].ProjectID,
		GetToken: func(_ context.Context, force bool) (string, error) {
			if force {
				return b.Token, nil // the host login now belongs to someone else
			}
			return a.Token, nil
		}})
	defer client.Close()
	if _, err := client.Call(ctx, "inbox.history", nil); err != nil {
		t.Fatal(err)
	}
	// Revoking A's session forces a refresh, which yields B's identity on the same client.
	if _, err := service.RevokeSession(ctx, a.SessionID); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Call(ctx, "inbox.history", nil); apiCode(err) != "FORBIDDEN" {
		t.Fatalf("expected FORBIDDEN when the account changes, got %v", err)
	}
}

func TestSubscriptionRecoversAfterConnectionLossAndCloseReleases(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	ctx := context.Background()
	client, _ := h.user(0, "", nil)
	sub, _ := client.Subscribe("inbox.recent", nil)
	ready(t, sub)
	var created item
	if err := client.CallInto(ctx, "inbox.add", map[string]any{"text": "before"}, &created); err != nil {
		t.Fatal(err)
	}
	until(t, "item arrives", func() bool { return len(items(sub)) == 1 })
	var mu sync.Mutex
	var statuses []fyrlet.Status
	sub.OnChange(func(s fyrlet.State) { mu.Lock(); statuses = append(statuses, s.Status); mu.Unlock() })
	generation := sub.State().Generation
	if err := client.Reconnect(ctx); err != nil {
		t.Fatal(err)
	}
	ready(t, sub)
	until(t, "new generation", func() bool { return sub.State().Generation != generation })
	mu.Lock()
	sawRecovering := false
	for _, s := range statuses {
		sawRecovering = sawRecovering || s == fyrlet.StatusRecovering
	}
	mu.Unlock()
	if !sawRecovering {
		t.Fatal("listener never saw the recovering state")
	}
	if got := items(sub); len(got) != 1 || got[0].ID != created.ID {
		t.Fatalf("unexpected data after recovery: %+v", got)
	}
	client.Close()
	if sub.State().Status != fyrlet.StatusClosed {
		t.Fatal("subscription should be closed")
	}
	if _, err := client.Call(ctx, "inbox.history", nil); apiCode(err) != "CLIENT_CLOSED" {
		t.Fatalf("expected CLIENT_CLOSED, got %v", err)
	}
	if _, err := client.Subscribe("inbox.recent", nil); apiCode(err) != "CLIENT_CLOSED" {
		t.Fatalf("expected CLIENT_CLOSED, got %v", err)
	}
}

func TestListenerPanicsDoNotBreakTheClient(t *testing.T) {
	endpoint, projects := setup(t)
	h := &harness{t, endpoint, projects}
	var mu sync.Mutex
	recovered := 0
	client, _ := h.user(0, "", func(o *fyrlet.Options) { o.OnListenerError = func(any) { mu.Lock(); recovered++; mu.Unlock() } })
	sub, _ := client.Subscribe("inbox.recent", nil)
	sub.OnChange(func(fyrlet.State) { panic("boom") })
	ready(t, sub)
	until(t, "panic reported", func() bool { mu.Lock(); defer mu.Unlock(); return recovered > 0 })
}

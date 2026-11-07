// Package fyrlet is the Go client for Fyrlet: authenticated operations plus recoverable realtime
// subscriptions over Phoenix Channels.
package fyrlet

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// maxJoinRetries is the number of consecutive retryable join failures of one subscription before it is
// reported as failed.
const maxJoinRetries = 10

var capabilityName = regexp.MustCompile(`^[a-z][a-z0-9_.-]*$`)

// Options configures a Client.
type Options struct {
	// Endpoint is the HTTP(S) base URL of the Fyrlet server.
	Endpoint string
	// ProjectID is the project this client is bound to.
	ProjectID string
	// GetToken returns a short-lived user session token ("rts_..."). With forceRefresh set, revalidate the host
	// login and obtain a new session, or return an *APIError with code UNAUTHENTICATED to stop recovery.
	GetToken func(ctx context.Context, forceRefresh bool) (string, error)
	// Timeout bounds each HTTP request and socket reply. Default 10s.
	Timeout time.Duration
	// RetryDelay returns the backoff before reconnect attempt n (1-based). Default 250ms doubling to 30s.
	RetryDelay func(attempt int) time.Duration
	// DisableDelta requests full snapshots only.
	DisableDelta bool
	// Capabilities lists optional capabilities to negotiate, as name -> version.
	Capabilities map[string]int
	// HTTPClient overrides the HTTP client. Redirects are never followed.
	HTTPClient *http.Client
	// NewID generates idempotency keys and subscription IDs. Default: random UUIDs.
	NewID func() string
	// OnListenerError receives panics recovered from listeners.
	OnListenerError func(recovered any)
}

type identity struct{ ProjectID, SubjectID string }

// Client is bound to one project and one user and is safe for concurrent use.
type Client struct {
	opts     Options
	endpoint string
	hc       *http.Client
	declared map[string]int
	events   *dispatcher

	tokenMu sync.Mutex // serializes token refreshes

	mu              sync.Mutex
	entries         map[string]*entry
	conn            *connection
	identity        *identity
	token           string
	epoch           int
	connectingEpoch int // -1 when idle
	retries         int
	retryTimer      *time.Timer
	closed          bool
}

// NewClient validates the options and returns a Client. No network access happens until first use.
func NewClient(opts Options) (*Client, error) {
	endpoint, err := endpointURL(opts.Endpoint)
	if err != nil {
		return nil, err
	}
	if opts.ProjectID == "" {
		return nil, errors.New("fyrlet: ProjectID is required")
	}
	if opts.GetToken == nil {
		return nil, errors.New("fyrlet: GetToken is required")
	}
	for name, version := range opts.Capabilities {
		if !capabilityName.MatchString(name) || version < 1 {
			return nil, errors.New("fyrlet: capabilities must be names with a positive integer version")
		}
	}
	if opts.Timeout <= 0 {
		opts.Timeout = 10 * time.Second
	}
	if opts.NewID == nil {
		opts.NewID = uuid
	}
	hc := &http.Client{}
	if opts.HTTPClient != nil {
		copied := *opts.HTTPClient
		hc = &copied
	}
	hc.CheckRedirect = noRedirects
	return &Client{
		opts: opts, endpoint: endpoint, hc: hc, declared: opts.Capabilities, events: newDispatcher(),
		entries: map[string]*entry{}, connectingEpoch: -1,
	}, nil
}

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// ---- operations --------------------------------------------------------------------------------

// CallOption customizes one operation.
type CallOption func(*callOptions)

type callOptions struct{ key string }

// WithIdempotencyKey reuses an idempotency key, for example when retrying after an unknown outcome.
func WithIdempotencyKey(key string) CallOption { return func(o *callOptions) { o.key = key } }

// MutationStatus is the outcome of one operation.
type MutationStatus string

const (
	// MutationCompleted is a successful read.
	MutationCompleted MutationStatus = "completed"
	// MutationCommitted is a write committed to the database.
	MutationCommitted MutationStatus = "committed"
	// MutationAccepted is a Run or ingest accepted for later execution.
	MutationAccepted MutationStatus = "accepted"
	// MutationFailed is a definite failure: nothing was written.
	MutationFailed MutationStatus = "failed"
	// MutationUnknown means the write was dispatched but its result was not seen. Use Recover.
	MutationUnknown MutationStatus = "unknown"
)

// MutationState is a snapshot of a Mutation.
type MutationState struct {
	Status MutationStatus
	Data   json.RawMessage
	Err    error
}

// RecoveryResult is a stored receipt: Status is committed or accepted with Data, or unknown.
type RecoveryResult struct {
	Status MutationStatus
	Data   json.RawMessage
}

// Mutation keeps the outcome of an operation so an unknown result can be recovered later.
type Mutation struct {
	IdempotencyKey string
	mu             sync.Mutex
	state          MutationState
	lookup         func(context.Context) (RecoveryResult, error)
}

// State returns the current outcome.
func (m *Mutation) State() MutationState {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.state
}

// Result returns the business result or the original error.
func (m *Mutation) Result() (json.RawMessage, error) {
	state := m.State()
	switch state.Status {
	case MutationCompleted, MutationCommitted, MutationAccepted:
		return state.Data, nil
	}
	return nil, state.Err
}

// Recover queries the stored receipt of an unknown write without executing it again.
func (m *Mutation) Recover(ctx context.Context) (MutationState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.state.Status != MutationUnknown {
		return m.state, nil
	}
	found, err := m.lookup(ctx)
	if err != nil {
		return m.state, err
	}
	if found.Status != MutationUnknown {
		m.state = MutationState{Status: found.Status, Data: found.Data}
	}
	return m.state, nil
}

// Call runs an operation and returns its business result as raw JSON.
//
// The SDK generates an idempotency key. After a network interruption the outcome of a write is unknown and
// the error is an *OutcomeUnknownError carrying the key for Recover. Reuse that key explicitly if you
// decide to submit the write again.
func (c *Client) Call(ctx context.Context, name string, input any, options ...CallOption) (json.RawMessage, error) {
	return c.Mutate(ctx, name, input, options...).Result()
}

// CallInto is Call decoding the result into out.
func (c *Client) CallInto(ctx context.Context, name string, input any, out any, options ...CallOption) error {
	data, err := c.Call(ctx, name, input, options...)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}

// Mutate is Call that never fails itself: inspect the returned Mutation.
func (c *Client) Mutate(ctx context.Context, name string, input any, options ...CallOption) *Mutation {
	var chosen callOptions
	for _, option := range options {
		option(&chosen)
	}
	key := chosen.key
	if key == "" {
		key = c.opts.NewID()
	}
	body := map[string]any{"input": orEmpty(input)}
	lookup := func(ctx context.Context) (RecoveryResult, error) { return c.recover(ctx, name, body, key) }
	if err := c.assertOpen(); err != nil {
		return &Mutation{IdempotencyKey: key, state: MutationState{Status: MutationFailed, Err: err}, lookup: lookup}
	}
	sent := false
	env, err := c.execute(ctx, func(ctx context.Context, token string) (*envelope, error) {
		sent = true
		env, err := c.do(ctx, http.MethodPost, operationPath(name), token, body, key)
		var api *APIError
		if errors.As(err, &api) && api.Status >= 400 && api.Status < 500 && api.Code != "PROTOCOL_ERROR" && api.Code != "HTTP_ERROR" {
			sent = false // a definite rejection: nothing was written
		}
		return env, err
	})
	if err == nil && env.Outcome != "completed" && env.Outcome != "committed" && env.Outcome != "accepted" {
		err = newError("PROTOCOL_ERROR", "Invalid operation outcome", false)
	}
	switch {
	case err == nil:
		return &Mutation{IdempotencyKey: key, state: MutationState{Status: MutationStatus(env.Outcome), Data: env.Data}, lookup: lookup}
	case sent:
		return &Mutation{IdempotencyKey: key, state: MutationState{Status: MutationUnknown,
			Err: &OutcomeUnknownError{Operation: name, IdempotencyKey: key, Cause: err}}, lookup: lookup}
	default:
		return &Mutation{IdempotencyKey: key, state: MutationState{Status: MutationFailed, Err: err}, lookup: lookup}
	}
}

// Recover looks up the stored receipt of a write without executing it.
func (c *Client) Recover(ctx context.Context, name string, input any, idempotencyKey string) (RecoveryResult, error) {
	if err := c.assertOpen(); err != nil {
		return RecoveryResult{}, err
	}
	return c.recover(ctx, name, map[string]any{"input": orEmpty(input)}, idempotencyKey)
}

// Contract returns the business contract this server exports.
func (c *Client) Contract(ctx context.Context) (json.RawMessage, error) {
	env, err := c.execute(ctx, func(ctx context.Context, token string) (*envelope, error) {
		return c.do(ctx, http.MethodGet, "/api/v1/contract", token, nil, "")
	})
	if err != nil {
		return nil, err
	}
	return env.Data, nil
}

func orEmpty(input any) any {
	if input == nil {
		return map[string]any{}
	}
	return input
}

func operationPath(name string) string { return "/api/v1/operations/" + url.PathEscape(name) }

func (c *Client) recover(ctx context.Context, name string, body map[string]any, key string) (RecoveryResult, error) {
	env, err := c.execute(ctx, func(ctx context.Context, token string) (*envelope, error) {
		return c.do(ctx, http.MethodPost, operationPath(name)+"/recover", token, body, key)
	})
	if err != nil {
		return RecoveryResult{}, err
	}
	switch env.Outcome {
	case "unknown":
		if string(env.Data) == "null" {
			return RecoveryResult{Status: MutationUnknown}, nil
		}
	case "committed", "accepted":
		return RecoveryResult{Status: MutationStatus(env.Outcome), Data: env.Data}, nil
	}
	return RecoveryResult{}, newError("PROTOCOL_ERROR", "Invalid recovery outcome", false)
}

// do performs one authenticated HTTP request bounded by Options.Timeout.
func (c *Client) do(ctx context.Context, method, path, token string, body any, key string) (*envelope, error) {
	headers := map[string]string{"authorization": "Bearer " + token, "x-project-id": c.opts.ProjectID}
	if key != "" {
		headers["idempotency-key"] = key
	}
	if len(c.declared) > 0 {
		names := make([]string, 0, len(c.declared))
		for name, version := range c.declared {
			names = append(names, fmt.Sprintf("%s=%d", name, version))
		}
		sort.Strings(names)
		headers["x-fyrlet-capabilities"] = strings.Join(names, ", ")
	}
	attempt, cancel := context.WithTimeout(ctx, c.opts.Timeout)
	defer cancel()
	env, err := doJSON(attempt, c.hc, method, c.endpoint+path, headers, body)
	if err != nil && ctx.Err() == nil && errors.Is(err, context.DeadlineExceeded) {
		return nil, newError("TIMEOUT", "The request timed out", true)
	}
	return env, err
}

// execute authorizes, runs perform and refreshes the token at most once after an authentication failure.
func (c *Client) execute(ctx context.Context, perform func(ctx context.Context, token string) (*envelope, error)) (*envelope, error) {
	token, err := c.authorize(ctx, false, "")
	if err != nil {
		return nil, c.authFailure(err)
	}
	env, err := perform(ctx, token)
	var api *APIError
	if errors.As(err, &api) && (api.Status == 401 || api.Code == "UNAUTHENTICATED") {
		if err = c.assertOpen(); err == nil {
			var fresh string
			if fresh, err = c.authorize(ctx, true, token); err == nil {
				env, err = perform(ctx, fresh)
			}
		}
	}
	if err != nil {
		return nil, c.authFailure(err)
	}
	return env, nil
}

func (c *Client) authFailure(err error) error {
	var api *APIError
	if errors.As(err, &api) && (api.Code == "UNAUTHENTICATED" || api.Code == "FORBIDDEN") {
		c.failAll(api)
	}
	return err
}

func (c *Client) authorize(ctx context.Context, force bool, stale string) (string, error) {
	c.tokenMu.Lock()
	defer c.tokenMu.Unlock()
	c.mu.Lock()
	token, closed := c.token, c.closed
	c.mu.Unlock()
	if closed {
		return "", errClosed()
	}
	// Another caller already refreshed past the token this one failed with.
	if token != "" && (!force || (stale != "" && token != stale)) {
		return token, nil
	}
	fresh, err := c.userToken(ctx, force)
	if err != nil {
		return "", err
	}
	id, err := c.identityFor(ctx, fresh)
	var api *APIError
	if errors.As(err, &api) && !force && api.Status == 401 {
		if fresh, err = c.userToken(ctx, true); err != nil {
			return "", err
		}
		id, err = c.identityFor(ctx, fresh)
	}
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return "", errClosed()
	}
	if id.ProjectID != c.opts.ProjectID || (c.identity != nil && id.SubjectID != c.identity.SubjectID) {
		return "", newError("FORBIDDEN", "Create a new client when changing accounts", false)
	}
	c.identity, c.token = &id, fresh
	return fresh, nil
}

func (c *Client) userToken(ctx context.Context, force bool) (string, error) {
	token, err := c.opts.GetToken(ctx, force)
	if err != nil {
		return "", err
	}
	if err := c.assertOpen(); err != nil {
		return "", err
	}
	if !strings.HasPrefix(token, "rts_") {
		return "", newError("UNAUTHENTICATED", "GetToken must return a user session token", false)
	}
	return token, nil
}

func (c *Client) identityFor(ctx context.Context, token string) (identity, error) {
	env, err := c.do(ctx, http.MethodGet, "/api/v1/identity", token, nil, "")
	if err != nil {
		return identity{}, err
	}
	var data struct {
		ProjectID string `json:"project_id"`
		SubjectID string `json:"subject_id"`
	}
	if json.Unmarshal(env.Data, &data) != nil || data.ProjectID == "" || data.SubjectID == "" {
		return identity{}, newError("PROTOCOL_ERROR", "Invalid identity response", false)
	}
	return identity{data.ProjectID, data.SubjectID}, nil
}

func errClosed() *APIError { return newError("CLIENT_CLOSED", "The client is closed", false) }

func (c *Client) assertOpen() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return errClosed()
	}
	return nil
}

// ---- subscriptions -------------------------------------------------------------------------------

// Subscribe starts a realtime subscription. Observe it with Subscription.OnChange.
func (c *Client) Subscribe(name string, params any) (*Subscription, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil, errClosed()
	}
	id := c.opts.NewID()
	if _, duplicate := c.entries[id]; duplicate {
		return nil, errors.New("fyrlet: NewID returned a duplicate subscription ID")
	}
	if params == nil {
		params = map[string]any{}
	}
	e := &entry{id: id, name: name, params: params, wantDelta: !c.opts.DisableDelta,
		state: State{Status: StatusConnecting}, listeners: map[int]func(State){}}
	c.entries[id] = e
	if c.conn != nil {
		c.attach(e, c.conn, c.epoch)
	} else {
		c.start(false)
	}
	return &Subscription{client: c, entry: e}, nil
}

func (c *Client) refresh(ctx context.Context, e *entry) error {
	c.mu.Lock()
	conn := e.conn
	if e.state.Status != StatusReady || conn == nil {
		c.mu.Unlock()
		return newError("NOT_READY", "The subscription is not ready", false)
	}
	c.mu.Unlock()
	result := make(chan error, 1)
	err := conn.push(e.topic(), "refresh", map[string]any{}, func(status string, response map[string]any) {
		switch status {
		case "ok":
			result <- nil
		case "error":
			result <- channelError(response)
		default:
			result <- newError("TIMEOUT", "refresh was not acknowledged", true)
		}
	})
	if err != nil {
		return err
	}
	select {
	case err := <-result:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *Client) unsubscribe(e *entry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, present := c.entries[e.id]; !present {
		return
	}
	delete(c.entries, e.id)
	c.cancelRejoin(e)
	conn := e.conn
	e.conn = nil
	if conn != nil {
		conn.leave(e.topic())
	}
	e.state = State{Status: StatusClosed, Generation: e.state.Generation, Seq: e.state.Seq}
	c.emit(e)
	e.listeners = map[int]func(State){}
	if len(c.entries) == 0 {
		c.detach()
	}
}

// Reconnect explicitly rebuilds the connection and the retained subscriptions.
func (c *Client) Reconnect(ctx context.Context) error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errClosed()
	}
	c.detach()
	c.recovering()
	epoch, retained := c.epoch, len(c.entries) > 0
	c.mu.Unlock()
	if !retained {
		return nil
	}
	if err := c.connect(ctx, true, epoch); err != nil {
		c.mu.Lock()
		c.connectionFailed(err, epoch)
		c.mu.Unlock()
		return err
	}
	return nil
}

// Close releases subscriptions, timers and connections. The client cannot be reused.
func (c *Client) Close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.detach()
	for _, e := range c.entries {
		e.state = State{Status: StatusClosed}
		c.emit(e)
		e.listeners = map[int]func(State){}
	}
	c.entries = map[string]*entry{}
	c.token = ""
	c.mu.Unlock()
	c.events.stop()
}

// ---- connection management (callers hold c.mu unless noted) --------------------------------------------

func (c *Client) start(force bool) {
	epoch := c.epoch
	if c.connectingEpoch == epoch {
		return
	}
	c.connectingEpoch = epoch
	go func() {
		if err := c.connect(context.Background(), force, epoch); err != nil {
			c.mu.Lock()
			c.connectionFailed(err, epoch)
			c.mu.Unlock()
		}
	}()
}

// connect runs without the lock held.
func (c *Client) connect(ctx context.Context, force bool, epoch int) error {
	defer func() {
		c.mu.Lock()
		if c.connectingEpoch == epoch {
			c.connectingEpoch = -1
		}
		c.mu.Unlock()
	}()
	token, err := c.authorize(ctx, force, "")
	if err != nil {
		return err
	}
	c.mu.Lock()
	stale := c.closed || c.epoch != epoch || len(c.entries) == 0 || c.conn != nil
	c.mu.Unlock()
	if stale {
		return nil
	}
	conn, err := dial(ctx, c.endpoint, c.opts.ProjectID, token, c.opts.Timeout, c.onFrame, c.onClose)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.epoch != epoch || len(c.entries) == 0 {
		conn.close()
		return nil
	}
	c.conn = conn
	for _, e := range c.entries {
		if e.state.Status != StatusError {
			c.attach(e, conn, epoch)
		}
	}
	return nil
}

func (c *Client) joinPayload(e *entry) map[string]any {
	payload := map[string]any{"protocol_version": protocolVersion, "name": e.name, "params": e.params}
	if len(c.declared) > 0 {
		payload["capabilities"] = c.declared
	}
	if e.wantDelta {
		payload["delivery"] = "delta-v1"
	}
	return payload
}

func (c *Client) current(e *entry, conn *connection, epoch int) bool {
	_, present := c.entries[e.id]
	return !c.closed && c.epoch == epoch && e.conn == conn && present
}

func (c *Client) attach(e *entry, conn *connection, epoch int) {
	e.conn = conn
	_ = conn.join(e.topic(), c.joinPayload(e), func(status string, response map[string]any) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if !c.current(e, conn, epoch) {
			return
		}
		switch status {
		case "ok":
			c.retries = 0
			e.joinFailures = 0
			c.receive(e, conn, "snapshot", response, true)
		case "error":
			err := channelError(response)
			switch {
			case err.Code == "UNAUTHENTICATED":
				c.transportFailed(conn)
			case err.Retryable && e.joinFailures < maxJoinRetries:
				// For example the observer was briefly unavailable: retry this subscription only.
				e.joinFailures++
				e.state.Status, e.state.Err = StatusRecovering, nil
				c.emit(e)
				c.scheduleRejoin(e, conn, epoch)
			default:
				c.fail(e, err)
			}
		default:
			c.transportFailed(conn)
		}
	})
}

func (c *Client) scheduleRejoin(e *entry, conn *connection, epoch int) {
	c.cancelRejoin(e)
	e.rejoin = time.AfterFunc(c.delay(e.joinFailures), func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		e.rejoin = nil
		if c.current(e, conn, epoch) {
			c.attach(e, conn, epoch)
		}
	})
}

func (c *Client) cancelRejoin(e *entry) {
	if e.rejoin != nil {
		e.rejoin.Stop()
		e.rejoin = nil
	}
}

func (c *Client) delay(attempt int) time.Duration {
	if c.opts.RetryDelay != nil {
		return c.opts.RetryDelay(attempt)
	}
	shift := attempt - 1
	if shift > 7 {
		shift = 7
	}
	if shift < 0 {
		shift = 0
	}
	return min(250*time.Millisecond<<shift, 30*time.Second)
}

func (c *Client) onFrame(conn *connection, f frame) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if conn != c.conn || c.closed || !strings.HasPrefix(f.topic, "subscription:") {
		return
	}
	e := c.entries[strings.TrimPrefix(f.topic, "subscription:")]
	if e == nil || e.conn != conn {
		return
	}
	switch f.event {
	case "snapshot", "delta":
		c.receive(e, conn, f.event, f.payload, false)
	case "status":
		err := channelError(f.payload)
		switch {
		case err.Code == "UNAUTHENTICATED":
			for _, item := range c.entries {
				item.state.Data = nil
			}
			c.transportFailed(conn)
		case err.Retryable:
			c.transportFailed(conn)
		default:
			c.fail(e, err)
		}
	case "phx_error":
		c.transportFailed(conn)
	case "phx_close":
		c.fail(e, newError("SUBSCRIPTION_CLOSED", "The server closed the subscription", false))
	}
}

func (c *Client) onClose(conn *connection, failure *APIError) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if conn != c.conn || c.closed {
		return
	}
	if failure != nil && !failure.Retryable {
		c.failAllLocked(failure)
		return
	}
	c.transportFailed(conn)
}

func (c *Client) receive(e *entry, conn *connection, event string, payload map[string]any, initial bool) {
	before := e.state
	var sent *ack
	var err error
	if event == "snapshot" {
		sent, err = e.applySnapshot(payload, c.identity, initial)
	} else {
		sent, err = e.applyDelta(payload)
	}
	var api *APIError
	switch {
	case err == errReconnect:
		c.transportFailed(conn)
		return
	case errors.As(err, &api):
		c.fail(e, api)
		return
	}
	if e.state.Seq != before.Seq || e.state.Status != before.Status || e.state.Generation != before.Generation {
		c.emit(e)
	}
	if sent != nil {
		_ = conn.notify(e.topic(), "ack", map[string]any{"g": sent.generation, "s": sent.seq})
	}
}

func (c *Client) transportFailed(conn *connection) {
	if conn != c.conn || c.closed {
		return
	}
	c.detach()
	c.recovering()
	c.scheduleRetry()
}

func (c *Client) connectionFailed(err error, epoch int) {
	if c.closed || c.epoch != epoch {
		return
	}
	if errors.Is(err, context.Canceled) {
		return
	}
	// A foreign error, such as a failing GetToken, counts as a retryable network failure.
	failure := asAPIError(err)
	if !failure.Retryable {
		c.failAllLocked(failure)
		return
	}
	c.recovering()
	c.scheduleRetry()
}

func (c *Client) scheduleRetry() {
	if c.closed || c.retryTimer != nil || len(c.entries) == 0 {
		return
	}
	c.retries++
	c.retryTimer = time.AfterFunc(c.delay(c.retries), func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		c.retryTimer = nil
		if !c.closed && len(c.entries) > 0 {
			c.start(true)
		}
	})
}

func (c *Client) recovering() {
	for _, e := range c.entries {
		if e.state.Status != StatusError {
			e.state.Status, e.state.Err = StatusRecovering, nil
			c.emit(e)
		}
	}
}

func (c *Client) failAll(err *APIError) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.failAllLocked(err)
}

func (c *Client) failAllLocked(err *APIError) {
	c.detach()
	c.token = ""
	for _, e := range c.entries {
		c.fail(e, err)
	}
}

func (c *Client) fail(e *entry, err *APIError) {
	c.cancelRejoin(e)
	conn := e.conn
	e.conn = nil
	if conn != nil {
		conn.leave(e.topic())
	}
	e.state.Status, e.state.Data, e.state.Err = StatusError, nil, err
	c.emit(e)
}

func (c *Client) detach() {
	c.epoch++
	c.connectingEpoch = -1
	if c.retryTimer != nil {
		c.retryTimer.Stop()
		c.retryTimer = nil
	}
	conn := c.conn
	c.conn = nil
	for _, e := range c.entries {
		c.cancelRejoin(e)
		e.conn = nil
	}
	if conn != nil {
		conn.close()
	}
}

// ---- listener dispatch -----------------------------------------------------------------------------

func (c *Client) emit(e *entry) {
	for _, listener := range e.listeners {
		c.dispatch(listener, e.state)
	}
}

func (c *Client) dispatch(listener func(State), state State) {
	c.events.post(func() {
		defer func() {
			if recovered := recover(); recovered != nil && c.opts.OnListenerError != nil {
				func() {
					defer func() { _ = recover() }()
					c.opts.OnListenerError(recovered)
				}()
			}
		}()
		listener(state)
	})
}

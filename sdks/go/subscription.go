package fyrlet

import (
	"context"
	"encoding/json"
	"math"
	"sync"
	"time"
)

const protocolVersion = 1

// Status is the lifecycle of a subscription.
type Status string

const (
	// StatusConnecting is the initial connection.
	StatusConnecting Status = "connecting"
	// StatusReady means the subscription holds a current snapshot.
	StatusReady Status = "ready"
	// StatusRecovering retains the previous Data while the connection is rebuilt.
	StatusRecovering Status = "recovering"
	// StatusError is terminal: Data is cleared and Err explains why.
	StatusError Status = "error"
	// StatusClosed is terminal: the subscription or client was closed.
	StatusClosed Status = "closed"
)

// State is what listeners see. Data is decoded JSON (arrays of map[string]any) and must be treated as
// read-only; later deltas never modify a previously delivered value.
type State struct {
	Status     Status
	Data       any
	Err        *APIError
	Generation string
	Seq        int64
}

// Decode copies Data into out, which is typically a pointer to a slice of your own record type.
func (s State) Decode(out any) error {
	encoded, err := json.Marshal(s.Data)
	if err != nil {
		return err
	}
	return json.Unmarshal(encoded, out)
}

type ack struct {
	generation string
	seq        int64
}

type entry struct {
	id        string
	name      string
	params    any
	wantDelta bool

	state        State
	listeners    map[int]func(State)
	nextListener int
	conn         *connection
	joinFailures int
	delta        bool
	rejoin       *time.Timer
}

func (e *entry) topic() string { return "subscription:" + e.id }

func integer(value any) (int64, bool) {
	number, ok := value.(float64)
	if !ok || number != math.Trunc(number) || math.Abs(number) > 1<<53 {
		return 0, false
	}
	return int64(number), true
}

// applySnapshot returns the ack to send, if any. Callers hold the client lock.
func (e *entry) applySnapshot(payload map[string]any, identity *identity, initial bool) (*ack, error) {
	generation, okGeneration := payload["generation"].(string)
	seq, okSeq := integer(payload["seq"])
	version, _ := integer(payload["protocol_version"])
	_, hasData := payload["data"]
	if payload == nil || version != protocolVersion || payload["subscription_id"] != e.id || identity == nil ||
		payload["project_id"] != identity.ProjectID || payload["subject_id"] != identity.SubjectID ||
		!okGeneration || !okSeq || seq < 1 || !hasData {
		return nil, newError("PROTOCOL_ERROR", "Invalid subscription snapshot", false)
	}
	if !initial && generation != e.state.Generation {
		return nil, nil
	}
	if initial {
		e.delta = payload["delivery"] == "delta-v1"
	}
	if initial || seq > e.state.Seq {
		e.state = State{Status: StatusReady, Data: payload["data"], Generation: generation, Seq: seq}
	}
	return &ack{generation, seq}, nil
}

var errReconnect = newError("RECONNECT", "sequence gap", true)

// applyDelta returns the ack to send, errReconnect on a sequence gap, or a protocol error.
func (e *entry) applyDelta(payload map[string]any) (*ack, error) {
	if payload["g"] != e.state.Generation {
		return nil, nil
	}
	seq, okSeq := integer(payload["s"])
	base, okBase := integer(payload["b"])
	if !e.delta || !okSeq || !okBase || seq < 2 || base < 1 || seq != base+1 {
		return nil, newError("PROTOCOL_ERROR", "Invalid subscription delta sequence", false)
	}
	generation := e.state.Generation
	if seq <= e.state.Seq {
		return &ack{generation, seq}, nil
	}
	if base != e.state.Seq {
		return nil, errReconnect
	}
	data, err := applyDelta(e.state.Data, payload["p"])
	if err != nil {
		return nil, newError("PROTOCOL_ERROR", "Invalid subscription delta", false)
	}
	e.state = State{Status: StatusReady, Data: data, Generation: generation, Seq: seq}
	return &ack{generation, seq}, nil
}

// Subscription is a handle to one realtime subscription. All methods are safe for concurrent use.
type Subscription struct {
	client *Client
	entry  *entry
}

// State returns the current state.
func (s *Subscription) State() State {
	s.client.mu.Lock()
	defer s.client.mu.Unlock()
	return s.entry.state
}

// OnChange registers a listener. It receives the current state first, then every change, serially on a
// dedicated goroutine, so it may call back into the client. The returned function removes it.
func (s *Subscription) OnChange(listener func(State)) (stop func()) {
	c := s.client
	c.mu.Lock()
	defer c.mu.Unlock()
	id := s.entry.nextListener
	s.entry.nextListener++
	s.entry.listeners[id] = listener
	c.dispatch(listener, s.entry.state)
	return func() {
		c.mu.Lock()
		delete(s.entry.listeners, id)
		c.mu.Unlock()
	}
}

// Refresh asks the server for a fresh snapshot. It returns once the server accepted the request; the data
// arrives through OnChange.
func (s *Subscription) Refresh(ctx context.Context) error { return s.client.refresh(ctx, s.entry) }

// Unsubscribe ends this subscription. It is safe to call more than once.
func (s *Subscription) Unsubscribe() { s.client.unsubscribe(s.entry) }

type dispatcher struct {
	mu     sync.Mutex
	queue  []func()
	wake   chan struct{}
	closed bool
}

func newDispatcher() *dispatcher {
	d := &dispatcher{wake: make(chan struct{}, 1)}
	go d.run()
	return d
}

func (d *dispatcher) post(job func()) {
	d.mu.Lock()
	if !d.closed {
		d.queue = append(d.queue, job)
	}
	d.mu.Unlock()
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

func (d *dispatcher) stop() {
	d.mu.Lock()
	d.closed = true
	d.mu.Unlock()
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

func (d *dispatcher) run() {
	for range d.wake {
		for {
			d.mu.Lock()
			if len(d.queue) == 0 {
				closed := d.closed
				d.mu.Unlock()
				if closed {
					return
				}
				break
			}
			job := d.queue[0]
			d.queue = d.queue[1:]
			d.mu.Unlock()
			job()
		}
	}
}

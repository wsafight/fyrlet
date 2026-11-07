package fyrlet

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	heartbeatInterval = 30 * time.Second
	maxBatch          = 64
	maxMessageBytes   = 4 << 20
)

type frame struct {
	joinRef *string
	ref     *string
	topic   string
	event   string
	payload map[string]any
}

// decodeFrames decodes one Phoenix frame or a {"batch":[...]} wrapper, validating every member.
func decodeFrames(raw []byte) ([]frame, error) {
	invalid := errors.New("invalid Fyrlet transport frame")
	var members []json.RawMessage
	var wrapper map[string]json.RawMessage
	if json.Unmarshal(raw, &wrapper) == nil && wrapper != nil {
		batch, ok := wrapper["batch"]
		if !ok || len(wrapper) != 1 || json.Unmarshal(batch, &members) != nil {
			return nil, invalid
		}
	} else {
		members = []json.RawMessage{raw}
	}
	if len(members) == 0 || len(members) > maxBatch {
		return nil, invalid
	}
	frames := make([]frame, 0, len(members))
	for _, member := range members {
		var parts []json.RawMessage
		if json.Unmarshal(member, &parts) != nil || len(parts) != 5 {
			return nil, invalid
		}
		var f frame
		for index, target := range []**string{&f.joinRef, &f.ref} {
			var value *string
			if json.Unmarshal(parts[index], &value) != nil {
				return nil, invalid
			}
			*target = value
		}
		if json.Unmarshal(parts[2], &f.topic) != nil || json.Unmarshal(parts[3], &f.event) != nil ||
			json.Unmarshal(parts[4], &f.payload) != nil || f.payload == nil {
			return nil, invalid
		}
		frames = append(frames, f)
	}
	return frames, nil
}

func socketURL(endpoint, projectID string) string {
	query := url.Values{"project_id": {projectID}, "vsn": {"2.0.0"}}
	return "ws" + strings.TrimPrefix(endpoint, "http") + "/socket/websocket?" + query.Encode()
}

func authProtocol(token string) string {
	return "base64url.bearer.phx." + base64.RawURLEncoding.EncodeToString([]byte(token))
}

type replyFunc func(status string, response map[string]any)

type pendingReply struct {
	reply replyFunc
	timer *time.Timer
}

// connection is one authenticated socket. onFrame runs on the reader goroutine, in order.
type connection struct {
	ws      *websocket.Conn
	timeout time.Duration
	onFrame func(*connection, frame)
	onClose func(*connection, *APIError)

	writeMu sync.Mutex
	mu      sync.Mutex
	pending map[string]*pendingReply
	refs    int
	closed  bool
	done    chan struct{}
}

func dial(ctx context.Context, endpoint, projectID, token string, timeout time.Duration,
	onFrame func(*connection, frame), onClose func(*connection, *APIError)) (*connection, error) {
	dialer := websocket.Dialer{HandshakeTimeout: timeout, Subprotocols: []string{"phoenix", authProtocol(token)}}
	ws, response, err := dialer.DialContext(ctx, socketURL(endpoint, projectID), nil)
	if err != nil {
		if response != nil {
			response.Body.Close()
			if response.StatusCode == 401 || response.StatusCode == 403 {
				return nil, &APIError{Code: "UNAUTHENTICATED", Message: "The socket rejected the session", Status: response.StatusCode}
			}
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, newError("NETWORK_ERROR", "The service could not be reached", true)
	}
	ws.SetReadLimit(maxMessageBytes)
	conn := &connection{
		ws: ws, timeout: timeout, onFrame: onFrame, onClose: onClose,
		pending: map[string]*pendingReply{}, done: make(chan struct{}),
	}
	go conn.read()
	go conn.heartbeat()
	return conn, nil
}

func (c *connection) nextRef() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.refs++
	return strconv.Itoa(c.refs)
}

func (c *connection) send(parts []any) error {
	encoded, err := json.Marshal(parts)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(c.timeout))
	err = c.ws.WriteMessage(websocket.TextMessage, encoded)
	c.writeMu.Unlock()
	if err != nil {
		failure := newError("NETWORK_ERROR", "The connection was interrupted", true)
		c.shutdown(failure, true)
		return failure
	}
	return nil
}

func (c *connection) register(ref string, reply replyFunc) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return false
	}
	c.pending[ref] = &pendingReply{reply: reply, timer: time.AfterFunc(c.timeout, func() {
		c.mu.Lock()
		entry := c.pending[ref]
		delete(c.pending, ref)
		c.mu.Unlock()
		if entry != nil {
			entry.reply("timeout", nil)
		}
	})}
	return true
}

func (c *connection) unregister(ref string) {
	c.mu.Lock()
	if entry := c.pending[ref]; entry != nil {
		entry.timer.Stop()
		delete(c.pending, ref)
	}
	c.mu.Unlock()
}

// push sends an event; reply receives "ok", "error" or "timeout" exactly once.
func (c *connection) push(topic, event string, payload any, reply replyFunc) error {
	ref := c.nextRef()
	if !c.register(ref, reply) {
		return newError("NETWORK_ERROR", "The connection was interrupted", true)
	}
	if err := c.send([]any{nil, ref, topic, event, payload}); err != nil {
		c.unregister(ref)
		return err
	}
	return nil
}

func (c *connection) join(topic string, payload any, reply replyFunc) error {
	ref := c.nextRef()
	if !c.register(ref, reply) {
		return newError("NETWORK_ERROR", "The connection was interrupted", true)
	}
	if err := c.send([]any{ref, ref, topic, "phx_join", payload}); err != nil {
		c.unregister(ref)
		return err
	}
	return nil
}

// notify sends an event without a ref, such as ack.
func (c *connection) notify(topic, event string, payload any) error {
	return c.send([]any{nil, nil, topic, event, payload})
}

func (c *connection) leave(topic string) {
	_ = c.send([]any{nil, c.nextRef(), topic, "phx_leave", map[string]any{}})
}

func (c *connection) close() { c.shutdown(nil, false) }

func (c *connection) read() {
	failure := newError("NETWORK_ERROR", "The connection was interrupted", true)
	for {
		_, raw, err := c.ws.ReadMessage()
		if err != nil {
			break
		}
		frames, err := decodeFrames(raw)
		if err != nil {
			failure = newError("PROTOCOL_ERROR", "Invalid transport frame", false)
			break
		}
		for _, f := range frames {
			if f.event == "phx_reply" && f.ref != nil {
				c.mu.Lock()
				entry := c.pending[*f.ref]
				delete(c.pending, *f.ref)
				c.mu.Unlock()
				if entry != nil {
					entry.timer.Stop()
					status, _ := f.payload["status"].(string)
					if status == "" {
						status = "error"
					}
					response, _ := f.payload["response"].(map[string]any)
					entry.reply(status, response)
				}
				continue
			}
			c.onFrame(c, f)
		}
	}
	c.shutdown(failure, true)
}

func (c *connection) heartbeat() {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			err := c.push("phoenix", "heartbeat", map[string]any{}, func(status string, _ map[string]any) {
				if status == "timeout" {
					c.shutdown(newError("NETWORK_ERROR", "Heartbeat timed out", true), true)
				}
			})
			if err != nil {
				return
			}
		}
	}
}

// shutdown closes the socket once. Callbacks run on their own goroutines because the caller may hold
// the client lock, which those callbacks take.
func (c *connection) shutdown(failure *APIError, notify bool) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	close(c.done)
	waiters := make([]*pendingReply, 0, len(c.pending))
	for _, entry := range c.pending {
		entry.timer.Stop()
		waiters = append(waiters, entry)
	}
	c.pending = map[string]*pendingReply{}
	c.mu.Unlock()
	_ = c.ws.Close()
	for _, waiter := range waiters {
		go waiter.reply("timeout", nil)
	}
	if notify {
		go c.onClose(c, failure)
	}
}

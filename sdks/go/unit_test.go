package fyrlet

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func decode(t *testing.T, raw string) any {
	t.Helper()
	var value any
	if err := json.Unmarshal([]byte(raw), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestDeltaChangesAndClearsWithoutMutatingInput(t *testing.T) {
	view := decode(t, `[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]`)
	out, err := applyDelta(view, decode(t, `{"c":[["a",{"text":"z"},["note"]]]}`))
	if err != nil {
		t.Fatal(err)
	}
	want := decode(t, `[{"id":"a","text":"z"},{"id":"b","text":"y"}]`)
	if !reflect.DeepEqual(any(out), want) {
		t.Fatalf("got %v want %v", out, want)
	}
	if !reflect.DeepEqual(view, decode(t, `[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]`)) {
		t.Fatal("input view was modified")
	}
}

func TestDeltaNullIsNotDeletionAndReorder(t *testing.T) {
	out, err := applyDelta(decode(t, `[{"id":"a","t":1}]`), decode(t, `{"c":[["a",{"t":null}]]}`))
	if err != nil || out[0].(map[string]any)["t"] != nil || len(out[0].(map[string]any)) != 2 {
		t.Fatalf("%v %v", out, err)
	}
	out, err = applyDelta(decode(t, `[{"id":"a"},{"id":"b"}]`), decode(t, `{"r":["a"],"a":[{"id":"c"}],"o":["c","b"]}`))
	if err != nil || out[0].(map[string]any)["id"] != "c" || out[1].(map[string]any)["id"] != "b" {
		t.Fatalf("%v %v", out, err)
	}
}

func TestDeltaRejectsInvalidPatches(t *testing.T) {
	for _, patch := range []string{
		`{"x":[]}`, `{"r":["missing"],"o":["a"]}`, `{"a":[{"id":"a"}],"o":["a"]}`, `{"c":[["a",{"id":"a"}]]}`,
		`{"c":[["a",{"t":1},["t"]]]}`, `{"c":[["a",{"t":1}],["a",{"t":2}]]}`, `{"r":["a"]}`, `{"c":[["zzz",{"t":1}]]}`,
	} {
		if _, err := applyDelta(decode(t, `[{"id":"a","t":0}]`), decode(t, patch)); err == nil {
			t.Errorf("accepted %s", patch)
		}
	}
}

func TestDecodeFrames(t *testing.T) {
	frame := `[null,"1","t","e",{}]`
	if frames, err := decodeFrames([]byte(frame)); err != nil || len(frames) != 1 || frames[0].topic != "t" || frames[0].joinRef != nil {
		t.Fatalf("%v %v", frames, err)
	}
	if frames, err := decodeFrames([]byte(`{"batch":[` + frame + `,` + frame + `]}`)); err != nil || len(frames) != 2 {
		t.Fatalf("%v %v", frames, err)
	}
	for _, bad := range []string{`[]`, `{"batch":[]}`, `{"batch":[` + strings.Repeat(frame+",", 64) + frame + `]}`,
		`{"batch":[` + frame + `],"x":1}`, `[1,2]`, `[null,null,"t","e",[]]`, `[null,null,"t","e",null]`, `nope`} {
		if _, err := decodeFrames([]byte(bad)); err == nil {
			t.Errorf("accepted %.40s", bad)
		}
	}
}

func TestSocketURLAndAuthProtocol(t *testing.T) {
	if got := socketURL("https://x.test", "p1"); got != "wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0" {
		t.Fatal(got)
	}
	if got := authProtocol("rts_abc"); got != "base64url.bearer.phx.cnRzX2FiYw" {
		t.Fatal(got)
	}
}

func TestEndpointValidation(t *testing.T) {
	if got, err := endpointURL("http://localhost:4000/"); err != nil || got != "http://localhost:4000" {
		t.Fatal(got, err)
	}
	for _, bad := range []string{"ftp://x", "http://u:p@x", "http://x?a=1", "http://x#f", "nope"} {
		if _, err := endpointURL(bad); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestErrors(t *testing.T) {
	err := channelError(decode(t, `{"error":{"code":"CONFLICT","message":"m"},"status":409}`).(map[string]any))
	if err.Code != "CONFLICT" || err.Status != 409 {
		t.Fatal(err)
	}
	if channelError(map[string]any{}).Code != "PROTOCOL_ERROR" {
		t.Fatal("expected protocol error")
	}
	var wrapped error = &OutcomeUnknownError{Operation: "op", IdempotencyKey: "k", Cause: newError("TIMEOUT", "t", true)}
	var api *APIError
	if !errors.As(wrapped, &api) || api.Code != "TIMEOUT" {
		t.Fatal("cause is not reachable")
	}
}

func snapshot(over map[string]any) map[string]any {
	base := map[string]any{"protocol_version": 1.0, "subscription_id": "s", "project_id": "p", "subject_id": "u",
		"generation": "g1", "seq": 1.0, "data": []any{map[string]any{"id": "a"}}, "delivery": "delta-v1"}
	for key, value := range over {
		base[key] = value
	}
	return base
}

var who = &identity{ProjectID: "p", SubjectID: "u"}

func newEntry() *entry {
	return &entry{id: "s", name: "n", wantDelta: true, state: State{Status: StatusConnecting}}
}

func TestEntrySnapshotAndDeltaFlow(t *testing.T) {
	e := newEntry()
	if got, err := e.applySnapshot(snapshot(nil), who, true); err != nil || got.seq != 1 || e.state.Status != StatusReady {
		t.Fatal(got, err)
	}
	got, err := e.applyDelta(decode(t, `{"g":"g1","b":1,"s":2,"p":{"c":[["a",{"t":1}]]}}`).(map[string]any))
	if err != nil || got.seq != 2 || e.state.Seq != 2 {
		t.Fatal(got, err)
	}
	if got, _ := e.applyDelta(decode(t, `{"g":"g1","b":1,"s":2,"p":{}}`).(map[string]any)); got == nil || got.seq != 2 {
		t.Fatal("duplicate should be re-acknowledged")
	}
	if got, err := e.applyDelta(decode(t, `{"g":"old","b":1,"s":2,"p":{}}`).(map[string]any)); got != nil || err != nil {
		t.Fatal("other generation should be ignored")
	}
	if _, err := e.applyDelta(decode(t, `{"g":"g1","b":3,"s":4,"p":{}}`).(map[string]any)); err != errReconnect {
		t.Fatal("gap should request a reconnect", err)
	}
}

func TestEntryRejectsForeignSnapshotsAndUnnegotiatedDeltas(t *testing.T) {
	for _, over := range []map[string]any{{"subject_id": "other"}, {"subscription_id": "x"}, {"seq": 0.0}, {"protocol_version": 2.0}} {
		if _, err := newEntry().applySnapshot(snapshot(over), who, true); err == nil {
			t.Errorf("accepted %v", over)
		}
	}
	e := newEntry()
	if _, err := e.applySnapshot(snapshot(map[string]any{"delivery": "snapshot"}), who, true); err != nil {
		t.Fatal(err)
	}
	if _, err := e.applyDelta(decode(t, `{"g":"g1","b":1,"s":2,"p":{}}`).(map[string]any)); err == nil {
		t.Fatal("accepted a delta that was not negotiated")
	}
}

func TestStateDecode(t *testing.T) {
	var items []struct {
		ID   string `json:"id"`
		Text string `json:"text"`
	}
	state := State{Data: decode(t, `[{"id":"a","text":"hi"}]`)}
	if err := state.Decode(&items); err != nil || items[0].Text != "hi" {
		t.Fatal(items, err)
	}
}

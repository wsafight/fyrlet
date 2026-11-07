package fyrlet

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// UserSession is a short-lived user session issued by a trusted backend.
type UserSession struct {
	Token     string `json:"token"`
	ProjectID string `json:"project_id"`
	SubjectID string `json:"subject_id"`
	SessionID string `json:"session_id"`
	ExpiresAt string `json:"expires_at"`
}

// SessionService exchanges application logins for Fyrlet user sessions. Use it only on trusted
// backends: the service key must never reach a browser or app binary.
type SessionService struct {
	endpoint string
	headers  map[string]string
	hc       *http.Client
}

// NewSessionService creates a SessionService. A nil client uses a 10 second timeout.
func NewSessionService(endpoint, serviceKey string, client *http.Client) (*SessionService, error) {
	if !strings.HasPrefix(serviceKey, "rtk_") {
		return nil, errors.New("fyrlet: expected a backend service key")
	}
	base, err := endpointURL(endpoint)
	if err != nil {
		return nil, err
	}
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	copied := *client
	copied.CheckRedirect = noRedirects
	return &SessionService{endpoint: base, headers: map[string]string{"authorization": "Bearer " + serviceKey}, hc: &copied}, nil
}

// IssueSessionInput describes the user to sign in. Issuer and TTLSeconds are optional.
type IssueSessionInput struct {
	ExternalSubject string `json:"external_subject"`
	Issuer          string `json:"issuer,omitempty"`
	TTLSeconds      int    `json:"ttl_seconds,omitempty"`
}

// IssueSession creates a session for an externally authenticated subject.
func (s *SessionService) IssueSession(ctx context.Context, input IssueSessionInput) (*UserSession, error) {
	env, err := doJSON(ctx, s.hc, http.MethodPost, s.endpoint+"/api/v1/sessions", s.headers, input)
	if err != nil {
		return nil, err
	}
	var session UserSession
	if err := json.Unmarshal(env.Data, &session); err != nil || session.Token == "" {
		return nil, newError("PROTOCOL_ERROR", "Invalid session response", false)
	}
	return &session, nil
}

// RevokeSession revokes one session of this project.
func (s *SessionService) RevokeSession(ctx context.Context, sessionID string) (bool, error) {
	env, err := doJSON(ctx, s.hc, http.MethodDelete, s.endpoint+"/api/v1/sessions/"+url.PathEscape(sessionID), s.headers, nil)
	if err != nil {
		return false, err
	}
	var result struct {
		Revoked bool `json:"revoked"`
	}
	if err := json.Unmarshal(env.Data, &result); err != nil {
		return false, newError("PROTOCOL_ERROR", "Invalid revoke response", false)
	}
	return result.Revoked, nil
}

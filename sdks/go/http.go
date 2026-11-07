package fyrlet

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
)

func endpointURL(endpoint string) (string, error) {
	u, err := url.Parse(endpoint)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("fyrlet: endpoint must be an HTTP(S) base URL without credentials, query or fragment")
	}
	return strings.TrimRight(endpoint, "/"), nil
}

// noRedirects stops bearer credentials from being forwarded to another host.
func noRedirects(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

type envelope struct {
	RequestID string          `json:"request_id"`
	Data      json.RawMessage `json:"data"`
	Outcome   string          `json:"outcome"`
	Error     *wireError      `json:"error"`
}

// doJSON performs one request and decodes the response envelope.
func doJSON(ctx context.Context, hc *http.Client, method, target string, headers map[string]string, body any) (*envelope, error) {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("accept", "application/json")
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	response, err := hc.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, newError("NETWORK_ERROR", "The service could not be reached", true)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 16<<20))
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, newError("NETWORK_ERROR", "The response was interrupted", true)
	}
	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, &APIError{Code: "PROTOCOL_ERROR", Message: "Expected a JSON response", Status: response.StatusCode}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 || env.Error != nil {
		if env.Error != nil {
			return nil, env.Error.toError(response.StatusCode, env.RequestID)
		}
		return nil, &APIError{Code: "HTTP_ERROR", Message: "The request was rejected", Status: response.StatusCode, RequestID: env.RequestID}
	}
	if env.Data == nil {
		return nil, &APIError{Code: "PROTOCOL_ERROR", Message: "Missing response data", Status: response.StatusCode}
	}
	return &env, nil
}

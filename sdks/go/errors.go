package fyrlet

import (
	"errors"
	"fmt"
)

// APIError is a failure reported by the server or detected by the SDK.
type APIError struct {
	Code      string
	Message   string
	Details   map[string]any
	Retryable bool
	Status    int
	RequestID string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("fyrlet: %s: %s", e.Code, e.Message)
}

// OutcomeUnknownError means a write was dispatched but its result is unknown. Use Client.Recover with
// IdempotencyKey before deciding to submit it again.
type OutcomeUnknownError struct {
	Operation      string
	IdempotencyKey string
	Cause          error
}

func (e *OutcomeUnknownError) Error() string {
	return fmt.Sprintf("fyrlet: the outcome of %s is unknown: %v", e.Operation, e.Cause)
}

func (e *OutcomeUnknownError) Unwrap() error { return e.Cause }

func newError(code, message string, retryable bool) *APIError {
	return &APIError{Code: code, Message: message, Retryable: retryable}
}

// asAPIError converts any error into an *APIError, treating foreign errors as network failures.
func asAPIError(err error) *APIError {
	var api *APIError
	if errors.As(err, &api) {
		return api
	}
	return newError("NETWORK_ERROR", "The service could not be reached", true)
}

type wireError struct {
	Code      *string        `json:"code"`
	Message   *string        `json:"message"`
	Details   map[string]any `json:"details"`
	Retryable bool           `json:"retryable"`
}

func (w *wireError) toError(status int, requestID string) *APIError {
	if w == nil || w.Code == nil || w.Message == nil {
		return &APIError{Code: "PROTOCOL_ERROR", Message: "Invalid error response", Status: status, RequestID: requestID}
	}
	return &APIError{Code: *w.Code, Message: *w.Message, Details: w.Details, Retryable: w.Retryable, Status: status, RequestID: requestID}
}

// channelError converts a Phoenix error reply into an *APIError.
func channelError(response map[string]any) *APIError {
	if raw, ok := response["error"].(map[string]any); ok {
		w := &wireError{}
		if code, ok := raw["code"].(string); ok {
			w.Code = &code
		}
		if message, ok := raw["message"].(string); ok {
			w.Message = &message
		}
		w.Details, _ = raw["details"].(map[string]any)
		w.Retryable, _ = raw["retryable"].(bool)
		status, _ := response["status"].(float64)
		return w.toError(int(status), "")
	}
	return newError("PROTOCOL_ERROR", "The server returned an invalid channel response", false)
}

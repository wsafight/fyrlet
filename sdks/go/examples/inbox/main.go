// Inbox runs against a running Fyrlet server:
//
//	FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... go run ./examples/inbox "First note"
//
// In a real application the SessionService runs on your backend and only the token reaches the client.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	fyrlet "github.com/wsafight/fyrlet/sdks/go"
)

func main() {
	ctx := context.Background()
	endpoint := os.Getenv("FYRLET_ENDPOINT")
	service, err := fyrlet.NewSessionService(endpoint, os.Getenv("FYRLET_SERVICE_KEY"), nil)
	if err != nil {
		log.Fatal(err)
	}
	client, err := fyrlet.NewClient(fyrlet.Options{
		Endpoint:  endpoint,
		ProjectID: os.Getenv("FYRLET_PROJECT_ID"),
		GetToken: func(ctx context.Context, forceRefresh bool) (string, error) {
			session, err := service.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: "example-user", TTLSeconds: 600})
			if err != nil {
				return "", err
			}
			return session.Token, nil
		},
	})
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	recent, err := client.Subscribe("inbox.recent", map[string]any{"limit": 20})
	if err != nil {
		log.Fatal(err)
	}
	recent.OnChange(func(state fyrlet.State) {
		var items []struct {
			Text string `json:"text"`
		}
		_ = state.Decode(&items)
		fmt.Println(state.Status, items)
	})

	texts := os.Args[1:]
	if len(texts) == 0 {
		texts = []string{"Hello from Go"}
	}
	for _, text := range texts {
		if _, err := client.Call(ctx, "inbox.add", map[string]any{"text": text}); err != nil {
			log.Fatal(err)
		}
	}
	time.Sleep(time.Second) // let the delta arrive before exiting
}

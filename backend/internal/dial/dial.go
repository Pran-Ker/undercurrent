// Package dial places phone calls on the owner's behalf through Dial (getdial.ai). A committed
// task that names a phone number is a call, not a coding job: the run dials, waits for the call to
// end, and brings the transcript back to the board. Off without DIAL_API_KEY.
package dial

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

type Client struct {
	Key  string
	From string        // DIAL_FROM_NUMBER: one of the account's numbers, E.164 or its id; empty lets Dial choose
	Base string        // DIAL_BASE_URL, default https://api.getdial.ai
	Poll time.Duration // between status checks
	HTTP *http.Client
}

// A Call is Dial's call object, the fields the board uses.
type Call struct {
	ID     string `json:"id"`
	From   string `json:"from"`
	To     string `json:"to"`
	Status struct {
		State           string `json:"state"`           // Queued · Ringing · In-Progress · Terminated
		TerminationType string `json:"terminationType"` // completed · busy · no-answer · failed · canceled
		Label           string `json:"label"`
	} `json:"status"`
	Duration   int              `json:"duration"`
	Transcript string           `json:"transcript"`
	Turns      []map[string]any `json:"transcriptTurns"`
	CreatedAt  string           `json:"createdAt"`
}

// New reads DIAL_API_KEY; nil without it.
func New() *Client {
	key := os.Getenv("DIAL_API_KEY")
	if key == "" {
		return nil
	}
	base := strings.TrimRight(os.Getenv("DIAL_BASE_URL"), "/")
	if base == "" {
		base = "https://api.getdial.ai"
	}
	return &Client{Key: key, From: os.Getenv("DIAL_FROM_NUMBER"), Base: base, Poll: 5 * time.Second, HTTP: &http.Client{Timeout: 30 * time.Second}}
}

var (
	e164 = regexp.MustCompile(`\+[1-9][0-9]{7,14}`)
	verb = regexp.MustCompile(`(?i)\b(call|phone|ring|dial)\b`)
)

// Number is the first phone number written in the text, E.164, or empty.
func Number(text string) string { return e164.FindString(text) }

// Wants says whether the text asks for a call: a call verb and a number to dial. A number alone
// (a contact to text, a code to note) is not a call.
func Wants(text string) (string, bool) {
	to := Number(text)
	return to, to != "" && verb.MatchString(text)
}

// Place starts an outbound call; the idempotency key keeps a retried placement from dialing twice.
func (c *Client) Place(to, instruction, idempotencyKey string) (Call, error) {
	body := map[string]any{"to": to, "outboundInstruction": instruction, "maxCallDurationSeconds": 240}
	if c.From != "" {
		body["fromNumber"] = c.From
	}
	return c.do("POST", "/api/v1/calls", body, idempotencyKey)
}

func (c *Client) Get(id string) (Call, error) { return c.do("GET", "/api/v1/calls/"+id, nil, "") }

// Wait polls until the call has ended and its transcript has landed (it follows the end by a
// little), or the timeout passes while the call is still going.
func (c *Client) Wait(id string, timeout time.Duration) (Call, error) {
	deadline := time.Now().Add(timeout)
	var ended time.Time
	for {
		call, err := c.Get(id)
		if err != nil {
			return call, err
		}
		if call.Status.State == "Terminated" {
			if call.Transcript != "" || call.Status.TerminationType != "completed" {
				return call, nil
			}
			if ended.IsZero() {
				ended = time.Now()
			}
			if time.Since(ended) > 90*time.Second {
				return call, nil
			}
		} else if time.Now().After(deadline) {
			return call, fmt.Errorf("call %s still %s after %s", id, call.Status.State, timeout)
		}
		time.Sleep(c.Poll)
	}
}

func (c *Client) do(method, path string, body any, idempotencyKey string) (Call, error) {
	var buf io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		buf = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.Base+path, buf)
	if err != nil {
		return Call{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Key)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return Call{}, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		return Call{}, fmt.Errorf("dial %s %s: HTTP %d %s", method, path, resp.StatusCode, clip(string(raw), 300))
	}
	var out struct {
		Call Call `json:"call"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return Call{}, fmt.Errorf("dial %s %s: %w", method, path, err)
	}
	return out.Call, nil
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

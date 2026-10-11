// Package events forwards the board's events to Keewano as small typed events — categories and
// counts, never text (S5). Off without KEEWANO_SDK_KEY; the local event table is the truth either way.
package events

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"log"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

const ingest = "https://api.keewano.com/event/ingress/v1/json"

// Registry is the one list of custom events, ids from 2000, append-only.
var Registry = []EventType{
	{2000, "TaskAdded", "none"}, {2001, "TaskStaged", "none"}, {2002, "TaskCommitted", "none"},
	{2003, "TaskClosed", "none"}, {2004, "TaskEdited", "none"}, {2005, "RunAsked", "none"},
	{2006, "RunDone", "none"}, {2007, "RunFailed", "none"}, {2008, "LiveToolCalled", "string"},
	{2009, "Restore", "none"}, {2010, "CallEnded", "none"},
}

type EventType struct {
	ID       int    `json:"eventTypeId"`
	Name     string `json:"name"`
	DataType string `json:"dataType"`
}

type Forwarder struct {
	key, install, session string
	hash                  uint32
	mu                    sync.Mutex
	registered            bool
	batch                 int
	Client                *http.Client
}

// New reads KEEWANO_SDK_KEY; the entity is one install (a UUID kept in meta), the session this
// process. Nil when there is no key, so callers can test for it.
func New(s *store.Store) *Forwarder {
	key := os.Getenv("KEEWANO_SDK_KEY")
	if key == "" {
		return nil
	}
	install := s.Meta("install_id")
	if install == "" {
		install = uuid()
		s.SetMeta("install_id", install)
	}
	return &Forwarder{key: key, install: install, session: uuid(), hash: Hash(Registry), Client: &http.Client{Timeout: 10 * time.Second}}
}

// Hash is the CRC32 of the sorted registry, as the Keewano quickstart computes it.
func Hash(types []EventType) uint32 {
	sorted := append([]EventType{}, types...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ID < sorted[j].ID })
	b, _ := json.Marshal(sorted)
	return crc32.ChecksumIEEE(b)
}

// OnEvent maps a board event to a typed Keewano event and sends it in the background.
func (f *Forwarder) OnEvent(e store.Event) {
	name, value := classify(e)
	if name == "" {
		return
	}
	go func() {
		if err := f.Send(name, value); err != nil {
			log.Printf("keewano: %v", err)
		}
	}()
}

func classify(e store.Event) (string, any) {
	switch e.Action {
	case "add":
		return "TaskAdded", nil
	case "stage":
		return "TaskStaged", nil
	case "commit":
		return "TaskCommitted", nil
	case "close":
		return "TaskClosed", nil
	case "edit", "retransform":
		return "TaskEdited", nil
	case "ask":
		return "RunAsked", nil
	case "hand_back":
		return "RunFailed", nil
	case "restore":
		return "Restore", nil
	case "call":
		return "CallEnded", nil
	}
	return "", nil
}

// Payload is what one event becomes on the wire — exported so a test can see it without a key.
func (f *Forwarder) Payload(name string, value any) (map[string]any, bool) {
	var et *EventType
	for i := range Registry {
		if Registry[i].Name == name {
			et = &Registry[i]
		}
	}
	if et == nil {
		return nil, false
	}
	ev := map[string]any{"eventTypeId": et.ID, "dataType": et.DataType, "timestamp": time.Now().Unix()}
	if et.DataType != "none" {
		ev["data"] = value
	}
	f.mu.Lock()
	f.batch++
	b := f.batch
	f.mu.Unlock()
	return map[string]any{"installId": f.install, "dataSessionId": f.session, "batch": b, "customEventsHash": f.hash, "events": []any{ev}}, true
}

func (f *Forwarder) Send(name string, value any) error {
	if err := f.register(); err != nil {
		return err
	}
	p, ok := f.Payload(name, value)
	if !ok {
		return fmt.Errorf("unregistered event %s", name)
	}
	return f.post("/in", p)
}

func (f *Forwarder) register() error {
	f.mu.Lock()
	done := f.registered
	f.mu.Unlock()
	if done {
		return nil
	}
	if err := f.post("/custom", map[string]any{"customEventsHash": f.hash, "eventTypes": Registry}); err != nil {
		return err
	}
	f.mu.Lock()
	f.registered = true
	f.mu.Unlock()
	return nil
}

func (f *Forwarder) post(path string, body any) error {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", ingest+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("k-token", f.key)
	resp, err := f.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("keewano %s: HTTP %d", path, resp.StatusCode)
	}
	return nil
}

func uuid() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

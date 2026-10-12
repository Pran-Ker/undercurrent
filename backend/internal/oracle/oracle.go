// Package oracle is recall: the board, the runs, the live sessions and the owner's coding-agent
// conversations, read at question time and cited. Nothing is stored here.
package oracle

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

type Hit struct {
	Source string
	Ref    string
	Text   string
	Score  int
}

// Recall ranks what mentions the words of the query. transcripts is a folder of JSONL
// conversations (Claude Code's, Codex's), newest first; empty skips it.
func Recall(s *store.Store, query, transcripts string, n int) string {
	words := tokens(query)
	if len(words) == 0 {
		return ""
	}
	var hits []Hit
	add := func(source, ref, text string) {
		if sc := score(text, words); sc > 0 {
			hits = append(hits, Hit{source, ref, clip(text, 220), sc})
		}
	}
	if tasks, err := s.Tasks(""); err == nil {
		for _, t := range tasks {
			add("task", t.ID+" ("+t.Stage+")", strings.Join([]string{t.Text, t.Context, t.Note}, " · "))
		}
	}
	if runs, err := s.Runs(""); err == nil {
		for _, r := range runs {
			if r.Result != "" {
				add("run", r.ID+" on "+r.TaskID, r.Result)
			}
		}
	}
	if sessions, err := s.Sessions(); err == nil {
		for _, x := range sessions {
			add("call", x.ConversationID, x.Summary)
		}
	}
	for _, c := range conversations(transcripts, 20) {
		add("conversation", c.ref, c.text)
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].Score > hits[j].Score })
	if len(hits) > n {
		hits = hits[:n]
	}
	var out []string
	for _, h := range hits {
		out = append(out, fmt.Sprintf("· [%s %s] %s", h.Source, h.Ref, h.Text))
	}
	return strings.Join(out, "\n")
}

type convo struct{ ref, text string }

// conversations reads the first user line and the last assistant line of each JSONL file.
func conversations(dir string, limit int) []convo {
	if dir == "" {
		return nil
	}
	dir = expand(dir)
	var files []string
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(p, ".jsonl") {
			files = append(files, p)
		}
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return mtime(files[i]).After(mtime(files[j])) })
	if len(files) > limit {
		files = files[:limit]
	}
	var out []convo
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var first, last string
		for _, line := range strings.Split(string(raw), "\n") {
			var d struct {
				Type    string `json:"type"`
				Message struct {
					Role    string          `json:"role"`
					Content json.RawMessage `json:"content"`
				} `json:"message"`
			}
			if json.Unmarshal([]byte(line), &d) != nil {
				continue
			}
			t := text(d.Message.Content)
			if t == "" || strings.HasPrefix(t, "<") {
				continue
			}
			role := d.Type
			if role == "" {
				role = d.Message.Role
			}
			if role == "user" && first == "" {
				first = t
			} else if role == "assistant" {
				last = t
			}
		}
		if first != "" || last != "" {
			out = append(out, convo{ref: filepath.Base(f) + " " + ago(mtime(f)), text: "began: " + clip(first, 160) + ", ended: " + clip(last, 160)})
		}
	}
	return out
}

func text(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		var parts []string
		for _, b := range blocks {
			if b.Type == "text" && b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}

func tokens(q string) []string {
	var out []string
	for _, w := range strings.Fields(strings.ToLower(q)) {
		w = strings.Trim(w, ".,;:!?\"'()")
		if len(w) > 2 {
			out = append(out, w)
		}
	}
	return out
}

func score(text string, words []string) int {
	t := strings.ToLower(text)
	n := 0
	for _, w := range words {
		if strings.Contains(t, w) {
			n++
		}
	}
	return n
}

func mtime(p string) time.Time {
	if st, err := os.Stat(p); err == nil {
		return st.ModTime()
	}
	return time.Time{}
}

func ago(t time.Time) string {
	h := time.Since(t).Hours()
	switch {
	case h < 1:
		return fmt.Sprintf("%d min ago", int(h*60))
	case h < 48:
		return fmt.Sprintf("%d h ago", int(h))
	}
	return fmt.Sprintf("%d days ago", int(h/24))
}

func expand(p string) string {
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func clip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

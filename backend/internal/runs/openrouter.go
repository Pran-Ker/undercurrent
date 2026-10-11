package runs

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// Chat is one chat-completions call, JSON mode, against OPENROUTER_BASE_URL with
// OPENROUTER_API_KEY and OPENROUTER_MODEL. Any OpenAI-compatible endpoint works.
func Chat(system, user string) (string, error) {
	key := os.Getenv("OPENROUTER_API_KEY")
	if key == "" {
		return "", fmt.Errorf("OPENROUTER_API_KEY is not set")
	}
	base := os.Getenv("OPENROUTER_BASE_URL")
	if base == "" {
		base = "https://openrouter.ai/api/v1"
	}
	model := os.Getenv("OPENROUTER_MODEL")
	if model == "" {
		model = "google/gemini-3.5-flash-lite"
	}
	body, _ := json.Marshal(map[string]any{
		"model": model, "temperature": 0.2, "max_tokens": 1500, "response_format": map[string]string{"type": "json_object"},
		"messages": []map[string]string{{"role": "system", "content": system}, {"role": "user", "content": user}},
	})
	req, _ := http.NewRequest("POST", base+"/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Title", "undercurrent")
	resp, err := (&http.Client{Timeout: 90 * time.Second}).Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("%s: HTTP %d: %s", model, resp.StatusCode, clip(string(raw), 300))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Choices) == 0 {
		return "", fmt.Errorf("%s: no choices: %s", model, clip(string(raw), 300))
	}
	return out.Choices[0].Message.Content, nil
}

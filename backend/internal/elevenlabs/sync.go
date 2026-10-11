// Package elevenlabs creates or updates the live agent from elevenlabs/agent.json, so its prompt
// and tools are reviewable in the repo. The ids it minted are kept in the meta table.
package elevenlabs

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

const api = "https://api.elevenlabs.io/v1"

type Spec struct {
	Name         string `json:"name"`
	FirstMessage string `json:"first_message"`
	Prompt       string `json:"prompt"`
	LLM          string `json:"llm,omitempty"`
	VoiceID      string `json:"voice_id,omitempty"`
	Tools        []Tool `json:"tools"`
}

type Tool struct {
	Name        string              `json:"name"`
	Description string              `json:"description"`
	Params      map[string]Property `json:"params"`
	Required    []string            `json:"required"`
}

type Property struct {
	Type        string `json:"type"`
	Description string `json:"description"`
}

type client struct {
	key string
	s   *store.Store
	log func(string, ...any)
}

// Sync creates every tool and the agent, or updates them when the meta table remembers their ids.
// publicURL is where the backend is reachable from ElevenLabs; secret is LIVE_TOOL_SECRET.
func Sync(s *store.Store, specPath, key, publicURL, secret string, log func(string, ...any)) (string, error) {
	raw, err := os.ReadFile(specPath)
	if err != nil {
		return "", err
	}
	var spec Spec
	if err := json.Unmarshal(raw, &spec); err != nil {
		return "", fmt.Errorf("%s: %w", specPath, err)
	}
	if key == "" || publicURL == "" || secret == "" {
		return "", fmt.Errorf("ELEVENLABS_API_KEY, PUBLIC_URL and LIVE_TOOL_SECRET are all needed")
	}
	c := &client{key, s, log}
	var toolIDs []string
	for _, t := range spec.Tools {
		id, err := c.tool(t, strings.TrimRight(publicURL, "/")+"/live/tools/"+t.Name, secret)
		if err != nil {
			return "", fmt.Errorf("tool %s: %w", t.Name, err)
		}
		toolIDs = append(toolIDs, id)
	}
	return c.agent(spec, toolIDs)
}

func (c *client) tool(t Tool, url, secret string) (string, error) {
	props := map[string]any{}
	for name, p := range t.Params {
		props[name] = map[string]any{"type": p.Type, "description": p.Description}
	}
	props["conversation_id"] = map[string]any{"type": "string", "dynamic_variable": "system__conversation_id"}
	body := map[string]any{"tool_config": map[string]any{
		"type": "webhook", "name": t.Name, "description": t.Description, "response_timeout_secs": 60,
		"api_schema": map[string]any{
			"url": url, "method": "POST", "content_type": "application/json",
			"request_body_schema": map[string]any{"type": "object", "properties": props, "required": t.Required},
			"request_headers":     map[string]any{"X-Live-Secret": secret},
		},
	}}
	key := "elevenlabs_tool_" + t.Name
	if id := c.s.Meta(key); id != "" {
		if _, err := c.do("PATCH", "/convai/tools/"+id, body); err == nil {
			c.log("  ✓ tool %s updated (%s)", t.Name, id)
			return id, nil
		}
	}
	out, err := c.do("POST", "/convai/tools", body)
	if err != nil {
		return "", err
	}
	id, _ := out["id"].(string)
	if id == "" {
		return "", fmt.Errorf("no id in %v", out)
	}
	c.s.SetMeta(key, id)
	c.log("  ✓ tool %s created (%s)", t.Name, id)
	return id, nil
}

func (c *client) agent(spec Spec, toolIDs []string) (string, error) {
	prompt := map[string]any{"prompt": spec.Prompt, "tool_ids": toolIDs}
	if spec.LLM != "" {
		prompt["llm"] = spec.LLM
	}
	agent := map[string]any{"first_message": spec.FirstMessage, "language": "en", "prompt": prompt}
	conv := map[string]any{"agent": agent}
	if spec.VoiceID != "" {
		conv["tts"] = map[string]any{"voice_id": spec.VoiceID}
	}
	body := map[string]any{"name": spec.Name, "conversation_config": conv,
		"platform_settings": map[string]any{"auth": map[string]any{"enable_auth": true}}}
	if id := c.s.Meta("elevenlabs_agent_id"); id != "" {
		if _, err := c.do("PATCH", "/convai/agents/"+id, body); err == nil {
			c.log("  ✓ agent %s updated (%s)", spec.Name, id)
			return id, nil
		} else {
			c.log("  · agent %s could not be updated (%v); creating anew", id, err)
		}
	}
	out, err := c.do("POST", "/convai/agents/create", body)
	if err != nil {
		return "", err
	}
	id, _ := out["agent_id"].(string)
	if id == "" {
		return "", fmt.Errorf("no agent_id in %v", out)
	}
	c.s.SetMeta("elevenlabs_agent_id", id)
	c.log("  ✓ agent %s created (%s)", spec.Name, id)
	return id, nil
}

func (c *client) do(method, path string, body any) (map[string]any, error) {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, api+path, bytes.NewReader(b))
	req.Header.Set("xi-api-key", c.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var out map[string]any
	json.Unmarshal(raw, &out)
	return out, nil
}

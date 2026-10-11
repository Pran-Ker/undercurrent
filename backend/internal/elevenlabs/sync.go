// Package elevenlabs creates or updates the voice agent from elevenlabs/agent.json, so its prompt
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
// Tools are client tools: the page or the app runs them against the local backend, so nothing
// here needs a public URL.
func Sync(s *store.Store, specPath, key string, log func(string, ...any)) (string, error) {
	raw, err := os.ReadFile(specPath)
	if err != nil {
		return "", err
	}
	var spec Spec
	if err := json.Unmarshal(raw, &spec); err != nil {
		return "", fmt.Errorf("%s: %w", specPath, err)
	}
	if key == "" {
		return "", fmt.Errorf("ELEVENLABS_API_KEY is needed")
	}
	c := &client{key, s, log}
	var toolIDs []string
	for _, t := range spec.Tools {
		id, err := c.tool(t)
		if err != nil {
			return "", fmt.Errorf("tool %s: %w", t.Name, err)
		}
		toolIDs = append(toolIDs, id)
	}
	return c.agent(spec, toolIDs)
}

func (c *client) tool(t Tool) (string, error) {
	props := map[string]any{}
	for name, p := range t.Params {
		props[name] = map[string]any{"type": p.Type, "description": p.Description}
	}
	body := map[string]any{"tool_config": map[string]any{
		"type": "client", "name": t.Name, "description": t.Description, "expects_response": true, "response_timeout_secs": 60,
		"parameters": map[string]any{"type": "object", "properties": props, "required": t.Required},
	}}
	key := "elevenlabs_tool_" + t.Name
	if id := c.s.Meta(key); id != "" {
		_, err := c.do("PATCH", "/convai/tools/"+id, body)
		if err == nil {
			c.log("  ✓ tool %s updated (%s)", t.Name, id)
			return id, nil
		}
		if !gone(err) {
			return "", fmt.Errorf("could not update %s: %w", id, err)
		}
		c.log("  · tool %s (%s) is gone from this account; creating it again", t.Name, id)
	}
	out, err := c.do("POST", "/convai/tools", body)
	if err != nil {
		return "", err
	}
	id, _ := out["id"].(string)
	if id == "" {
		return "", fmt.Errorf("no id in %v", out)
	}
	if err := c.s.SetMeta(key, id); err != nil {
		return "", fmt.Errorf("created tool %s (%s) but could not remember it: %w", t.Name, id, err)
	}
	c.log("  ✓ tool %s created (%s)", t.Name, id)
	return id, nil
}

func (c *client) agent(spec Spec, toolIDs []string) (string, error) {
	prompt := map[string]any{"prompt": spec.Prompt, "tool_ids": toolIDs}
	if spec.LLM != "" {
		prompt["llm"] = spec.LLM
	}
	agent := map[string]any{"first_message": spec.FirstMessage, "language": "en", "prompt": prompt,
		"dynamic_variables": map[string]any{"dynamic_variable_placeholders": map[string]any{"user_id": "owner", "board": "(not handed over at the start; call list_board)"}}}
	conv := map[string]any{"agent": agent}
	if spec.VoiceID != "" {
		conv["tts"] = map[string]any{"voice_id": spec.VoiceID}
	}
	body := map[string]any{"name": spec.Name, "conversation_config": conv,
		"platform_settings": map[string]any{"auth": map[string]any{"enable_auth": true}}}
	if id := c.s.Meta("elevenlabs_agent_id"); id != "" {
		_, err := c.do("PATCH", "/convai/agents/"+id, body)
		if err == nil {
			c.log("  ✓ agent %s updated (%s)", spec.Name, id)
			return id, nil
		}
		if !gone(err) {
			return "", fmt.Errorf("could not update agent %s: %w", id, err)
		}
		c.log("  · agent %s is gone from this account; creating it again", id)
	}
	out, err := c.do("POST", "/convai/agents/create", body)
	if err != nil {
		return "", err
	}
	id, _ := out["agent_id"].(string)
	if id == "" {
		return "", fmt.Errorf("no agent_id in %v", out)
	}
	if err := c.s.SetMeta("elevenlabs_agent_id", id); err != nil {
		return "", fmt.Errorf("created agent %s but could not remember it: %w", id, err)
	}
	c.log("  ✓ agent %s created (%s)", spec.Name, id)
	return id, nil
}

// gone is ElevenLabs saying the remembered id no longer exists (deleted, or another account's).
func gone(err error) bool { return strings.HasPrefix(err.Error(), "HTTP 404") }

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

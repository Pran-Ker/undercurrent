// Package config loads .env from the repo (the backend's parent) or the working directory, without
// overriding what the environment already has.
package config

import (
	"os"
	"path/filepath"
	"strings"
)

// UNDERCURRENT_DOTENV=0 skips the file: a throwaway local backend must not inherit the shared board.
func Load() {
	if os.Getenv("UNDERCURRENT_DOTENV") == "0" {
		return
	}
	for _, p := range []string{".env", filepath.Join("..", ".env")} {
		raw, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(raw), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			v = strings.Trim(strings.TrimSpace(v), `"`)
			if os.Getenv(k) == "" {
				os.Setenv(strings.TrimSpace(k), v)
			}
		}
		return
	}
}

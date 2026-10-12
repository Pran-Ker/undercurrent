// undercurrent, the backend: a board of tasks, the agents that run against them, the events
// that record every move.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/pran-ker/undercurrent/backend/internal/api"
	"github.com/pran-ker/undercurrent/backend/internal/config"
	"github.com/pran-ker/undercurrent/backend/internal/elevenlabs"
	"github.com/pran-ker/undercurrent/backend/internal/events"
	"github.com/pran-ker/undercurrent/backend/internal/store"
)

const usage = `undercurrent <command>

  serve             listen on $PORT (default 8787); migrates first
  migrate           apply the schema and migrations to the database and exit
  seed              load db/demo.sql (the demo set) after migrating
  elevenlabs sync   create or update the live agent and its tools from elevenlabs/agent.json

The database is TURSO_DATABASE_URL (+ TURSO_AUTH_TOKEN) or UNDERCURRENT_DB (file:…, the default
file:undercurrent.db). Settings come from the environment or .env, see .env.example.`

func main() {
	config.Load()
	if len(os.Args) < 2 {
		fmt.Println(usage)
		os.Exit(2)
	}
	s, err := store.Open()
	if err != nil {
		log.Fatal(err)
	}
	if err := s.Migrate(); err != nil {
		log.Fatal(err)
	}
	if n, err := s.SeedEvents(); err != nil {
		log.Fatal(err)
	} else if n > 0 {
		log.Printf("seeded %d events for tasks that had none", n)
	}
	switch os.Args[1] {
	case "migrate":
		fmt.Println("migrated")
	case "seed":
		body, err := os.ReadFile("db/demo.sql")
		if err != nil {
			log.Fatal(err)
		}
		if err := s.Seed(string(body)); err != nil {
			log.Fatal(err)
		}
		if err := s.Migrate(); err != nil { // the demo rows take their stages from the migration
			log.Fatal(err)
		}
		s.SeedEvents()
		fmt.Println("seeded")
	case "serve":
		if f := events.New(s); f != nil {
			s.OnEvent = f.OnEvent
			log.Printf("keewano: forwarding typed events")
		}
		if os.Getenv("DIAL_API_KEY") != "" {
			log.Printf("dial: a committed task that names a phone number is placed as a call")
		}
		port := os.Getenv("PORT")
		if port == "" {
			port = "8787"
		}
		log.Printf("undercurrent on http://127.0.0.1:%s", port)
		a := api.New(s)
		if n := a.Runner.Resume(); n > 0 {
			log.Printf("resumed %d queued runs", n)
		}
		log.Fatal(http.ListenAndServe(":"+port, a.Routes()))
	case "elevenlabs":
		if len(os.Args) < 3 || os.Args[2] != "sync" {
			fmt.Println(usage)
			os.Exit(2)
		}
		id, err := elevenlabs.Sync(s, filepath.Join("elevenlabs", "agent.json"), os.Getenv("ELEVENLABS_API_KEY"), log.Printf)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("agent %s, set ELEVENLABS_AGENT_ID=%s in .env\n", id, id)
	default:
		fmt.Println(usage)
		os.Exit(2)
	}
}

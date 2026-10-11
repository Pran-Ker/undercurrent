// undercurrent — the backend: a board of tasks, the agents that run against them, the events
// that record every move.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/pran-ker/undercurrent/backend/internal/api"
	"github.com/pran-ker/undercurrent/backend/internal/store"
)

const usage = `undercurrent <command>

  serve     listen on $PORT (default 8787); migrates first
  migrate   apply the schema and migrations to the database and exit
  seed      load db/demo.sql (the demo set) after migrating

The database is TURSO_DATABASE_URL (+ TURSO_AUTH_TOKEN) or UNDERCURRENT_DB (file:…, the default
file:undercurrent.db). See .env.example.`

func main() {
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
		fmt.Println("seeded")
	case "serve":
		port := os.Getenv("PORT")
		if port == "" {
			port = "8787"
		}
		log.Printf("undercurrent on http://127.0.0.1:%s", port)
		log.Fatal(http.ListenAndServe(":"+port, (&api.API{S: s}).Routes()))
	default:
		fmt.Println(usage)
		os.Exit(2)
	}
}

// Package store is the one place that opens the database: a local file for development and
// tests, or the Turso database when TURSO_DATABASE_URL is set.
package store

import (
	"database/sql"
	"embed"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"strings"
	"time"

	_ "github.com/tursodatabase/libsql-client-go/libsql"
	_ "modernc.org/sqlite"
)

//go:embed sql/*.sql
var sqlFiles embed.FS

type Store struct {
	DB      *sql.DB
	OnEvent func(Event) // set by main: the Keewano forwarder; nil in tests
}

// Open reads the environment: TURSO_DATABASE_URL (+ TURSO_AUTH_TOKEN), else UNDERCURRENT_DB
// (a `file:` path, default file:undercurrent.db).
func Open() (*Store, error) {
	if url := os.Getenv("TURSO_DATABASE_URL"); url != "" {
		db, err := sql.Open("libsql", url+"?authToken="+os.Getenv("TURSO_AUTH_TOKEN"))
		return &Store{DB: db}, err
	}
	path := os.Getenv("UNDERCURRENT_DB")
	if path == "" {
		path = "file:undercurrent.db"
	}
	return OpenFile(path)
}

func OpenFile(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return &Store{DB: db}, nil
}

// Migrate applies the schema and every migration, in order; a statement that has already been
// applied (a column that exists) is skipped, so this is safe to run on every start.
func (s *Store) Migrate() error {
	names, _ := sqlFiles.ReadDir("sql")
	var files []string
	for _, n := range names {
		files = append(files, n.Name())
	}
	sort.Strings(files)
	for _, f := range files {
		if s.Meta("migration:"+f) != "" {
			continue // applied before; the early files are idempotent anyway, the later ones rebuild tables
		}
		body, _ := sqlFiles.ReadFile("sql/" + f)
		for _, stmt := range statements(string(body)) {
			if stmt == "" {
				continue
			}
			if _, err := s.DB.Exec(stmt); err != nil && !strings.Contains(err.Error(), "duplicate column") {
				return fmt.Errorf("%s: %w\n%s", f, err, stmt)
			}
		}
		s.SetMeta("migration:"+f, Now()) // no meta table yet for the first files: fine, they run again harmlessly
	}
	return nil
}

// statements splits SQL text on the semicolons that end statements — not the ones inside a
// quoted string or a `-- …` comment, both of which the demo set has.
func statements(text string) []string {
	var out []string
	var cur strings.Builder
	inQuote := false
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case inQuote:
			cur.WriteByte(c)
			if c == '\'' {
				inQuote = false
			}
		case c == '\'':
			inQuote = true
			cur.WriteByte(c)
		case c == '-' && i+1 < len(text) && text[i+1] == '-':
			for i < len(text) && text[i] != '\n' {
				i++
			}
			cur.WriteByte('\n')
		case c == ';':
			out = append(out, strings.TrimSpace(cur.String()))
			cur.Reset()
		default:
			cur.WriteByte(c)
		}
	}
	if rest := strings.TrimSpace(cur.String()); rest != "" {
		out = append(out, rest)
	}
	return out
}

// Seed loads a SQL file of inserts (the demo set).
func (s *Store) Seed(body string) error {
	for _, stmt := range statements(body) {
		if stmt == "" || strings.EqualFold(stmt, "BEGIN") || strings.EqualFold(stmt, "COMMIT") {
			continue
		}
		if _, err := s.DB.Exec(stmt); err != nil {
			return err
		}
	}
	return nil
}

const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"

// NewID is four random base36 characters with at least one digit.
func NewID() string {
	for {
		b := make([]byte, 4)
		digit := false
		for i := range b {
			b[i] = alphabet[rand.Intn(len(alphabet))]
			digit = digit || b[i] <= '9'
		}
		if digit {
			return string(b)
		}
	}
}

func Now() string   { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }
func Today() string { return time.Now().UTC().Format("2006-01-02") }

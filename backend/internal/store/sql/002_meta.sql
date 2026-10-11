-- Small facts the backend keeps about itself: the ids it minted on outside services, the install id.
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

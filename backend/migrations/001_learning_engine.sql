CREATE TABLE IF NOT EXISTS b_entities(
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  course_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  data TEXT NOT NULL CHECK(json_valid(data)),
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS b_entities_scope ON b_entities(user_id, course_id, kind);
CREATE TABLE IF NOT EXISTS b_jobs(
  job_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, course_id TEXT NOT NULL,
  kind TEXT NOT NULL, payload TEXT NOT NULL CHECK(json_valid(payload)),
  status TEXT NOT NULL CHECK(status IN ('queued','running','succeeded','failed')),
  progress INTEGER NOT NULL DEFAULT 0, result_ref TEXT, error_code TEXT, error_message TEXT,
  retryable INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, lease_until TEXT,
  idempotency_key TEXT, request_hash TEXT,
  UNIQUE(user_id,course_id,kind,idempotency_key)
);
CREATE INDEX IF NOT EXISTS b_jobs_queue ON b_jobs(status,created_at);
CREATE TABLE IF NOT EXISTS b_events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL, course_id TEXT NOT NULL, data TEXT NOT NULL CHECK(json_valid(data))
);
CREATE INDEX IF NOT EXISTS b_events_scope ON b_events(user_id,seq);
CREATE TABLE IF NOT EXISTS b_idempotency(
  user_id TEXT NOT NULL, course_id TEXT NOT NULL, scope TEXT NOT NULL, key TEXT NOT NULL,
  request_hash TEXT NOT NULL, entity_id TEXT NOT NULL,
  PRIMARY KEY(user_id,course_id,scope,key)
);
CREATE TABLE IF NOT EXISTS b_versions(
  user_id TEXT NOT NULL, course_id TEXT NOT NULL, version INTEGER NOT NULL,
  PRIMARY KEY(user_id,course_id)
);

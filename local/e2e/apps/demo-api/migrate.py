"""Idempotent migration — run by infra before each new version goes live (MIGRATE_CMD)."""
import os

import psycopg

with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
    conn.execute("CREATE TABLE IF NOT EXISTS visits (id serial PRIMARY KEY, at timestamptz DEFAULT now())")
print("migrations applied")

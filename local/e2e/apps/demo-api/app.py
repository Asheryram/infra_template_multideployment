"""demo-api: tells you exactly how it is wired — env, branch, version, database, feature flags."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

VERSION = "v1"
MESSAGE = "hello from demo-api"


def db_info():
    url = os.environ.get("DATABASE_URL")
    if not url:
        return {"ok": False, "error": "no DATABASE_URL"}
    try:
        with psycopg.connect(url, connect_timeout=3) as conn:
            conn.execute("INSERT INTO visits DEFAULT VALUES")
            visits = conn.execute("SELECT count(*) FROM visits").fetchone()[0]
            name = conn.execute("SELECT current_database()").fetchone()[0]
        return {"ok": True, "database": name, "host": os.environ.get("PGHOST"), "visits": visits}
    except Exception as e:  # report, don't crash: the point is to SEE the wiring
        return {"ok": False, "error": str(e).splitlines()[0]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            body = {"ok": True}
        else:
            body = {
                "service": "demo-api",
                "version": VERSION,
                "message": MESSAGE,
                "env": os.environ.get("APP_ENV"),
                "branch": os.environ.get("GIT_BRANCH"),
                "commit": (os.environ.get("GIT_COMMIT") or "")[:8],
                "feature": {"new_feature_key_set": bool(os.environ.get("NEW_FEATURE_KEY"))},
                "db": db_info(),
            }
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8080))), Handler).serve_forever()

#!/usr/bin/env python3
"""Project links of one project, for deploy.sh (read-only):   project-links.py <console-access.sqlite3> <app>

Prints, one per line:
  <service>|<path(s) or *>|<project>|<target service>|<env or empty>|<strip true|false>|<paths|fetch>|<excluded prefixes>   this project's services route to another project
  HIDE|<service>                                                                                        this project's service has no public address of its own
Links are created in the console (Access → Project links) by a platform admin or the organization's admin. They are
deliberately NOT read from infra.yml: that file comes from the repository, so anyone who can open a pull request
could otherwise declare a route into another project.
"""
import os
import sqlite3
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: project-links.py <db> <app>", file=sys.stderr)
        return 2
    db_path, app = sys.argv[1:]
    if not os.path.isfile(db_path):
        return 0
    try:
        db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
        rows = db.execute("SELECT service, path, provider, provider_service, env, strip, mode, excludes FROM project_links "
                          "WHERE consumer=? ORDER BY path", (app,)).fetchall()
        hidden = db.execute("SELECT DISTINCT provider_service FROM project_links WHERE provider=? AND hide_provider=1", (app,)).fetchall()
    except sqlite3.OperationalError:
        return 0                                   # table not created yet: no links
    for svc, path, prov, psvc, env, strip, mode, excl in rows:
        print(f"{svc}|{path}|{prov}|{psvc}|{env or ''}|{'true' if strip else 'false'}|{mode or 'paths'}|{excl or ''}")
    for (psvc,) in hidden:
        print(f"HIDE|{psvc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

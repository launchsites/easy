"""Read the app's first-run workspace without changing it."""

from contextlib import closing
import hashlib
import json
import sqlite3

from native_ui_soak import chunked_document


def read_pending_workspace(database):
    with closing(sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True, timeout=2)) as db:
        revision = db.execute("""
            SELECT revision, kind, workspace, gym_sessions, workout_plans
            FROM revisions ORDER BY revision DESC LIMIT 1
        """).fetchone()
        if revision is None:
            return False
        application_id = db.execute("PRAGMA application_id").fetchone()
        if revision[:2] != (1, "migration") or application_id != (0x45535931,):
            raise RuntimeError("The app's initial database has an unexpected identity or revision.")
        if db.execute("PRAGMA quick_check(1)").fetchone() != ("ok",):
            raise RuntimeError("The app's initial database failed SQLite quick_check.")

        documents = {}
        for digest in dict.fromkeys(revision[2:]):
            raw = chunked_document(db, digest)
            if hashlib.sha256(raw).hexdigest() != digest:
                raise RuntimeError("The app's initial document failed its digest check.")
            documents[digest] = json.loads(raw)
        workspace, sessions, plans = (documents[digest] for digest in revision[2:])
        if (
            workspace.get("workspaceSetup") != "pending"
            or any(workspace.get(key) != [] for key in ("events", "tasks", "notes"))
            or workspace.get("captures", []) != []
            or sessions != []
            or plans != []
        ):
            raise RuntimeError("The app did not initialize an empty workspace awaiting setup.")
        return True

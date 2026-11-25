#!/usr/bin/env python3
"""Exercise the packaged broker against an isolated APFS directory."""
import json
import os
from contextlib import closing
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time


RESUME_DOCUMENT = "Café Final.pdf"
RESUME_DOCUMENT_MATCH = "caf AND afe AND pdf"


def expose_paths(connection, source="main"):
    connection.execute(f"""
        CREATE TEMP VIEW indexed_entries AS
        SELECT e.rowid AS rowid, e.*, CASE WHEN e.parent IS NULL THEN p.path
            WHEN p.path = '/' THEN '/' || e.name ELSE p.path || '/' || e.name END AS path
        FROM {source}.entries e JOIN {source}.parent_paths p ON p.id = coalesce(e.parent, e.directory)
        """)


def verify(broker, base):
    root = base / "root"
    support = root / "index"
    support.mkdir(parents=True)
    (root / "work_%").mkdir()
    (root / "destination").mkdir()
    source = root / "work_%" / "start.txt"
    source.write_bytes(b"a" * 2048)
    (root / "archive.txt").write_bytes(b"b" * 128)
    (root / "symlink").symlink_to(root, target_is_directory=True)
    hidden = root / "protected"
    hidden.mkdir()
    (hidden / "inaccessible.txt").write_bytes(b"x" * 64)
    hidden.chmod(0)
    app_data = root / "Users" / "Example" / "Library" / "Group Containers"
    private_file = app_data / "com.example.test" / "document.txt"
    private_file.parent.mkdir(parents=True)
    private_file.write_text("Test data")
    signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(broker)],
                               capture_output=True, text=True).stderr
    local_build = "TeamIdentifier=not set" in signature
    db = support / "index.sqlite"
    status = support / "broker.json"
    environment = dict(os.environ, SPACETRAIL_ROOT=str(root), SPACETRAIL_SUPPORT=str(support))

    def query(sql, parameters=()):
        with closing(sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True)) as connection:
            expose_paths(connection)
            return connection.execute(sql, parameters).fetchall()

    def row(path):
        return query("SELECT kind, logical, files FROM indexed_entries WHERE path = ?", (str(path),))

    def usage(path):
        return query("""
            SELECT f.exclusive, f.shared, f.measured, f.incomplete
            FROM indexed_entries e JOIN folder_footprints f ON f.entry_id=e.rowid WHERE e.path = ?
            """, (str(path),))

    def wait(condition, description, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if condition():
                    return
            except (sqlite3.Error, FileNotFoundError):
                pass
            time.sleep(0.15)
        info = status.read_text() if status.exists() else "No broker status"
        raise AssertionError(f"{description}: {info}")

    def start():
        return subprocess.Popen([broker], env=environment)

    def stop(process):
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

    process = start()
    try:
        wait(lambda: json.loads(status.read_text())["phase"] == "monitoring", "first scan")
        assert row(source) == [(0, 2048, 1)], (source, query("SELECT path, kind, logical FROM indexed_entries"))
        assert row(source.parent) == [(1, 2048, 1)]
        assert query("""
            SELECT e.name FROM name_fts JOIN entries e ON e.rowid = name_fts.rowid
            WHERE name_fts MATCH '"sta" AND "art"'
            """) == [("start.txt",)]
        assert row(root / "symlink")[0][0] == 2
        assert not row(support)
        assert query("SELECT path FROM gaps") == [(str(hidden),)]
        assert query("SELECT count(*) FROM samples") == [(1,)]
        assert query("PRAGMA auto_vacuum") == [(2,)]
        if local_build:
            assert not row(private_file)
            assert query("SELECT path FROM limited_scopes") == [(str(app_data),)]
            private_file.write_text("Updated test data")
            public_file = root / "Users" / "Example" / "Library" / "note.txt"
            public_file.write_bytes(b"abc")
            wait(lambda: row(public_file) == [(0, 3, 1)], "updates alongside protected containers")
            assert not row(private_file)

        source.write_bytes(b"x" * 8192)
        wait(lambda: row(source.parent) == [(1, 8192, 1)], "file modification and ancestor totals")
        wait(lambda: usage(source.parent) == [(8192, 0, 1, 0)], "disk usage updates from the broker alone")

        renamed = root / "destination" / "moved"
        source.parent.rename(renamed)
        wait(lambda: not row(source.parent) and row(renamed) == [(1, 8192, 1)]
             and row(renamed / source.name) == [(0, 8192, 1)], "directory rename and move")

        moved_file = root / "renamed.txt"
        (renamed / source.name).rename(moved_file)
        wait(lambda: row(moved_file) == [(0, 8192, 1)] and row(renamed) == [(1, 0, 0)],
             "single-file move")

        moved_file.unlink()
        wait(lambda: not row(moved_file), "file removal")
        assert query("SELECT count(*) FROM name_fts WHERE name_fts MATCH 'ren'") == [(0,)]

        created = renamed / "new.txt"
        created.write_bytes(b"b" * 384)
        wait(lambda: row(created) == [(0, 384, 1)], "file creation")

        hidden.chmod(0o700)
        wait(lambda: row(hidden / "inaccessible.txt") == [(0, 64, 1)]
             and not query("SELECT path FROM gaps"), "recovery of a newly accessible folder")

        checkpoint = int(query("SELECT value FROM meta WHERE key = 'event'")[0][0])
        assert checkpoint > 0
        assert query("SELECT value FROM meta WHERE key = 'journal'")[0][0]
        baseline = query("SELECT value FROM meta WHERE key = 'baselineAt'")
        stop(process)
        # An old database must keep its baseline, drop system aliases and backfill search.
        with sqlite3.connect(db) as connection:
            connection.executescript("""
                DROP TRIGGER search_insert;
                DROP TRIGGER search_delete;
                DROP TRIGGER search_rename;
                DROP TABLE name_fts;
                DELETE FROM meta WHERE key IN ('searchComplete', 'searchCursor', 'topology');
                INSERT INTO parent_paths(tree, path) VALUES (1, '/'), (1, '/Users');
                INSERT INTO entries(tree, directory, parent, name, name_key, kind, logical, allocated,
                                    files, modified, created, inode, mode, links) VALUES
                  (1, (SELECT id FROM parent_paths WHERE tree=1 AND path='/'),
                   NULL, 'System', 'system', 1, 2048, 4096, 1, 0, 0, 2, 0, 1),
                  (1, (SELECT id FROM parent_paths WHERE tree=1 AND path='/Users'),
                   (SELECT id FROM parent_paths WHERE tree=1 AND path='/'),
                   'Users', 'users', 1, 2048, 4096, 1, 0, 0, 3, 0, 1),
                  (1, NULL, (SELECT id FROM parent_paths WHERE tree=1 AND path='/Users'),
                   'archive.txt', 'archive.txt', 0, 2048, 4096, 1, 0, 0, 4, 0, 1);
                """)
        created.unlink()
        offline = renamed / "while-broker-stopped.txt"
        offline.write_bytes(b"z" * 768)
        time.sleep(3)
        process = start()
        wait(lambda: not row(created) and row(offline) == [(0, 768, 1)]
             and row(renamed) == [(1, 768, 1)], "FSEvents resumption after shutdown")

        assert query("SELECT value FROM meta WHERE key = 'baselineAt'") == baseline
        assert query("SELECT count(*) FROM name_fts WHERE name_fts MATCH 'arc'") == [(1,)]
        assert query("SELECT count(*) FROM name_fts WHERE name_fts MATCH 'sto AND top'") == [(1,)]
        assert not row("/Users")
        assert row("/") == [(1, 0, 0)]

        # Journal replacement schedules bounded repair, preserving the baseline.
        stop(process)
        physical = root / "physical"
        physical.mkdir()
        original = physical / "original.bin"
        original.write_bytes(os.urandom(131_072))
        subprocess.run(["/bin/cp", "-c", str(original), str(physical / "clone.bin")], check=True)
        hardlink = physical / "hard.bin"
        hardlink.write_bytes(os.urandom(8_192))
        peer = physical / "subfolder"
        peer.mkdir()
        (peer / "link.bin").hardlink_to(hardlink)
        unique = physical / "unique.bin"
        unique.write_bytes(os.urandom(32_768))
        with sqlite3.connect(db) as connection:
            connection.execute("UPDATE meta SET value = 'old-journal' WHERE key = 'journal'")
        process = start()
        wait(lambda: row(physical) == [(1, 311_296, 5)], "reconciliation after journal replacement")

        # Measurements arrive and stay available with the dashboard closed.
        expected = [(32_768, 139_264, 5, 0)]
        wait(lambda: usage(physical) == expected and usage(peer) == [(0, 8_192, 1, 0)],
             "background accounting for clones and hard links across folders")
        stop(process)
        assert usage(physical) == expected
        assert not (support / "footprint-request.json").exists()
        process = start()
        moved = peer / unique.name
        unique.rename(moved)
        wait(lambda: usage(peer) == [(32_768, 8_192, 2, 0)] and usage(physical) == expected,
             "move and updated estimates for both folders")
        moved.unlink()
        wait(lambda: usage(physical) == [(0, 139_264, 4, 0)] and usage(peer) == [(0, 8_192, 1, 0)],
             "removal and refreshed saved estimates")

        direct = physical / "created-in-background.bin"
        direct.write_bytes(os.urandom(16_384))
        wait(lambda: usage(physical) == [(16_384, 139_264, 5, 0)], "file creation with the app closed")
        clone = peer / "cloned-in-background.bin"
        subprocess.run(["/bin/cp", "-c", str(direct), str(clone)], check=True)
        wait(lambda: usage(physical) == [(0, 155_648, 6, 0)], "clone created after its source was measured")
        assert query("SELECT value FROM meta WHERE key = 'baselineAt'") == baseline
        assert query("SELECT count(*) FROM pending_repair") == [(0,)]
        assert query("PRAGMA quick_check") == [("ok",)]
        assert query("""
            SELECT e.path FROM indexed_entries e
            WHERE e.kind = 1 AND
            (e.logical <> (SELECT coalesce(sum(c.logical), 0) FROM entries c WHERE c.parent=e.directory)
            OR e.allocated <> (SELECT coalesce(sum(c.allocated), 0) FROM entries c WHERE c.parent=e.directory)
            OR e.files <> (SELECT coalesce(sum(c.files), 0) FROM entries c WHERE c.parent=e.directory))
            """) == []
    finally:
        hidden.chmod(0o700)
        stop(process)


def verify_resume(broker, base):
    root = base / "root"
    support = base / "index"
    group_sizes = [4096, 16384, 4096, 4096, 4096, 4096, 4096, 4096]
    for group, size in enumerate(group_sizes):
        folder = root / f"{group:02}"
        folder.mkdir(parents=True)
        for item in range(size):
            (folder / f"file-{item}.txt").touch()
    db = support / "index.sqlite"
    environment = dict(os.environ, SPACETRAIL_ROOT=str(root), SPACETRAIL_SUPPORT=str(support))

    def checkpoint_state():
        with closing(sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True)) as connection:
            metadata = dict(connection.execute("SELECT key, value FROM meta"))
            partial = connection.execute("""
                SELECT 1 FROM pending_scan p JOIN parent_paths d ON d.tree=p.tree AND d.path=p.path
                JOIN entries e ON e.tree=p.tree AND e.parent=d.id
                WHERE p.path = ? LIMIT 1
                """, (str(root / "01"),)).fetchone()
            return metadata, partial is not None

    process = subprocess.Popen([broker], env=environment)
    try:
        deadline = time.monotonic() + 30
        checkpoint = {}
        while time.monotonic() < deadline:
            try:
                checkpoint, partial = checkpoint_state()
                if partial and int(checkpoint.get("initialCount", 0)) >= 4096:
                    break
            except sqlite3.Error:
                pass
            time.sleep(0.025)
        process.send_signal(signal.SIGKILL)
        process.wait(timeout=5)
        checkpoint, partial = checkpoint_state()
        assert partial and int(checkpoint["initialCount"]) >= 4096 and "baseline" not in checkpoint, checkpoint

        # Mutations in a completed folder must be picked up by the saved FSEvents watermark.
        (root / "00" / "file-0.txt").unlink()
        (root / "00" / RESUME_DOCUMENT).write_bytes(b"payload")
        # A deletion in the in-flight directory must not survive a replay of that directory.
        (root / "01" / "file-0.txt").unlink()
        time.sleep(3)
        process = subprocess.Popen([broker], env=environment)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = json.loads((support / "broker.json").read_text())
            if state["pid"] == process.pid and state["phase"] == "monitoring":
                break
            assert state["phase"] != "failed", state
            time.sleep(0.15)
        assert state["pid"] == process.pid and state["phase"] == "monitoring", state
        assert checkpoint_state()[0]["initialWatermark"] == checkpoint["initialWatermark"]
        with closing(sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True)) as connection:
            assert connection.execute("SELECT count(*) FROM pending_scan").fetchone() == (0,)
            assert connection.execute("SELECT logical, files FROM entries WHERE parent IS NULL").fetchone() == (7, sum(group_sizes) - 1)
            assert connection.execute("SELECT count(*) FROM name_fts WHERE name_fts MATCH ?",
                                      (RESUME_DOCUMENT_MATCH,)).fetchone() == (1,)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    for version in (0, 1):
        verify_migration(broker, root, support, environment, version)


def verify_migration(broker, root, support, environment, version):
    database = support / "index.sqlite"
    legacy = support / "legacy.sqlite"
    sample = (int(time.time()) // 3600 * 3600 - 48 * 3600, 10000, 5000, 1000)
    with closing(sqlite3.connect(database)) as modern:
        assert modern.execute("PRAGMA journal_mode = DELETE").fetchone() == ("delete",)

    with closing(sqlite3.connect(legacy)) as connection:
        connection.execute("ATTACH DATABASE ? AS modern", (str(database),))
        expose_paths(connection, "modern")
        matching_documents = connection.execute("""
            SELECT e.rowid, e.path FROM modern.name_fts JOIN indexed_entries e ON e.rowid=name_fts.rowid
            WHERE name_fts MATCH ? ORDER BY e.rowid
            """, (RESUME_DOCUMENT_MATCH,)).fetchall()
        assert any(path == str(root / "00" / RESUME_DOCUMENT) for _, path in matching_documents)
        if version == 1:
            (schema,) = connection.execute("SELECT sql FROM modern.sqlite_schema WHERE name = 'parent_paths'").fetchone()
            connection.execute(schema)
            connection.execute("INSERT INTO main.parent_paths SELECT * FROM modern.parent_paths")
        connection.executescript(f"""
            CREATE TABLE entries (
                tree INTEGER NOT NULL, path TEXT NOT NULL, parent {'INTEGER' if version == 1 else 'TEXT'}, name TEXT NOT NULL,
                name_key TEXT NOT NULL, kind INTEGER NOT NULL, logical INTEGER NOT NULL,
                allocated INTEGER NOT NULL, files INTEGER NOT NULL, modified REAL NOT NULL,
                created REAL NOT NULL, inode INTEGER NOT NULL, mode INTEGER NOT NULL,
                links INTEGER NOT NULL, {'id INTEGER PRIMARY KEY, UNIQUE(tree, path)' if version == 1 else 'PRIMARY KEY(tree, path)'}
            );
            INSERT INTO entries(rowid, tree, path, parent, name, name_key, kind, logical, allocated,
                                files, modified, created, inode, mode, links)
            SELECT e.rowid, e.tree, e.path, {'e.parent' if version == 1 else 'p.path'}, e.name, e.name_key, e.kind, e.logical,
                   e.allocated, e.files, e.modified, e.created, e.inode, e.mode, e.links
            FROM indexed_entries e LEFT JOIN modern.parent_paths p ON p.id = e.parent;
            PRAGMA user_version = {version};
            """)
        indexes = connection.execute("""
            SELECT sql FROM modern.sqlite_schema WHERE type = 'index' AND tbl_name = 'entries' AND sql IS NOT NULL
            AND name NOT IN ('folder_path', 'entry_location')
            """).fetchall()
        for (sql,) in indexes:
            connection.execute(sql)
        connection.execute("CREATE INDEX folder_path ON entries(tree, path) WHERE kind = 1")
        for table in ["meta", "samples", "gaps", "limited_scopes", "pending_scan", "pending_repair",
                      "file_footprints", "folder_footprints", "folder_shares", "footprint_priority", "footprint_peers"]:
            (schema,) = connection.execute("SELECT sql FROM modern.sqlite_schema WHERE name = ?", (table,)).fetchone()
            connection.execute(schema)
            connection.execute(f"INSERT INTO {table} SELECT * FROM modern.{table}")
        connection.executescript("""
            CREATE VIRTUAL TABLE name_fts USING fts5(
                name_key, content='entries', tokenize='trigram case_sensitive 1', detail=none, columnsize=0
            );
            INSERT INTO name_fts(name_fts) VALUES ('rebuild');
            """)
        connection.execute("INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?)", sample)
        connection.commit()
        baseline = connection.execute("SELECT value FROM meta WHERE key='baselineAt'").fetchone()
        connection.execute("DROP VIEW indexed_entries")
        connection.execute("DETACH DATABASE modern")
        connection.execute("VACUUM")
        legacy_compact_bytes = legacy.stat().st_size
        connection.executescript("""
            CREATE TABLE discarded(data BLOB);
            INSERT INTO discarded VALUES (zeroblob(8388608));
            DROP TABLE discarded;
            """)
        assert connection.execute("PRAGMA freelist_count").fetchone()[0] > 1000
        if version == 1:
            assert connection.execute("PRAGMA journal_mode = WAL").fetchone() == ("wal",)
    old_bytes = legacy.stat().st_size
    legacy.replace(database)

    process = subprocess.Popen([broker], env=environment)
    try:
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            state = json.loads((support / "broker.json").read_text())
            if state["pid"] == process.pid and state["phase"] == "monitoring":
                break
            assert state["phase"] != "failed", state
            time.sleep(0.15)
        assert state["pid"] == process.pid and state["phase"] == "monitoring", state
        with closing(sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True)) as connection:
            expose_paths(connection)
            assert connection.execute("PRAGMA user_version").fetchone() == (2,)
            assert connection.execute("SELECT value FROM meta WHERE key='baselineAt'").fetchone() == baseline
            assert connection.execute("SELECT * FROM samples WHERE date=?", sample[:1]).fetchone() == sample
            assert connection.execute("""
                SELECT e.rowid, e.path FROM name_fts JOIN indexed_entries e ON e.rowid=name_fts.rowid
                WHERE name_fts MATCH ? ORDER BY e.rowid
                """, (RESUME_DOCUMENT_MATCH,)).fetchall() == matching_documents
            assert connection.execute("""
                SELECT count(*) FROM entries e
                LEFT JOIN parent_paths p ON p.id=e.parent
                LEFT JOIN parent_paths d ON d.id=e.directory
                WHERE (e.parent IS NOT NULL AND (p.id IS NULL OR p.tree <> e.tree))
                   OR ((e.kind = 1 OR e.parent IS NULL) AND (d.id IS NULL OR d.tree <> e.tree))
                """).fetchone() == (0,)
        assert database.stat().st_size < legacy_compact_bytes, (database.stat().st_size, legacy_compact_bytes)
        print(f"Fixture compaction from v{version} · {old_bytes:,} → {database.stat().st_size:,} bytes "
              f"(compacted legacy format · {legacy_compact_bytes:,} bytes).")
        added = root / f"Café Migrated v{version}.pdf"
        added.write_bytes(b"abc")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            with closing(sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True)) as connection:
                expose_paths(connection)
                result = connection.execute("""
                    SELECT e.path FROM name_fts JOIN indexed_entries e ON e.rowid=name_fts.rowid
                    WHERE name_fts MATCH 'mig AND gra AND pdf' AND e.name = ?
                    """, (added.name,)).fetchall()
                if result == [(str(added),)]:
                    break
            time.sleep(0.15)
        else:
            raise AssertionError("FSEvents and search after migration")
        if version == 1:
            # A deletion that spans several commits must leave a similarly named sibling alone.
            sibling = root / "01-neighbour"
            sibling.mkdir()
            (sibling / "keep.txt").write_text("keep")
            (root / "01").rename(root.parent / "retired")
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                with closing(sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True)) as connection:
                    expose_paths(connection)
                    paths = connection.execute("""
                        SELECT path FROM indexed_entries WHERE path IN (?, ?, ?)
                        """, (str(root / "01"), str(root / "01" / "file-1.txt"), str(sibling / "keep.txt"))).fetchall()
                    if paths == [(str(sibling / "keep.txt"),)]:
                        break
                time.sleep(0.15)
            else:
                raise AssertionError("multi-batch subtree deletion with directory references")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    default = Path(__file__).resolve().parents[1] / (
        "dist/SpaceTrail.app/Contents/Helpers/SpaceTrail Broker.app/Contents/MacOS/SpaceTrailBroker"
    )
    executable = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else default
    with tempfile.TemporaryDirectory(prefix="spacetrail-test-") as directory:
        verify(executable, Path(directory).resolve())
    with tempfile.TemporaryDirectory(prefix="spacetrail-resume-") as directory:
        verify_resume(executable, Path(directory).resolve())
    print("Verified scanning, search, APFS clones, FSEvents, resumption, and SQLite migration.")

use crate::{display_path, now, platform::Capacity};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params, params_from_iter, types::Value};
use serde::{Deserialize, Serialize, Serializer};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

const DATABASE: &str = "index.sqlite";
pub const PAGE_SIZE: usize = 150;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent INTEGER REFERENCES entries(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL,
    extension TEXT NOT NULL DEFAULT '',
    directory TEXT,
    logical INTEGER NOT NULL DEFAULT 0,
    allocated INTEGER NOT NULL DEFAULT 0,
    files INTEGER NOT NULL DEFAULT 0,
    estimates INTEGER NOT NULL DEFAULT 0,
    modified INTEGER NOT NULL DEFAULT 0,
    seen INTEGER NOT NULL DEFAULT 0,
    blocked INTEGER NOT NULL DEFAULT 0,
    UNIQUE(parent, name)
);
CREATE UNIQUE INDEX IF NOT EXISTS directory_path ON entries(directory) WHERE directory IS NOT NULL;
CREATE INDEX IF NOT EXISTS directory_id ON entries(id) WHERE directory IS NOT NULL;
CREATE INDEX IF NOT EXISTS file_size ON entries(allocated) WHERE directory IS NULL;
CREATE INDEX IF NOT EXISTS file_logical ON entries(logical) WHERE directory IS NULL;
CREATE INDEX IF NOT EXISTS file_modified ON entries(modified) WHERE directory IS NULL;
CREATE INDEX IF NOT EXISTS file_extension ON entries(extension, allocated) WHERE directory IS NULL;
CREATE INDEX IF NOT EXISTS by_name ON entries(name_key);
CREATE INDEX IF NOT EXISTS blocked_directories ON entries(blocked) WHERE blocked=1 AND directory IS NOT NULL;
CREATE INDEX IF NOT EXISTS by_parent_size ON entries(parent, allocated);
CREATE INDEX IF NOT EXISTS folder_size ON entries(allocated) WHERE directory IS NOT NULL;
CREATE TABLE IF NOT EXISTS pending (
    directory INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    walk INTEGER NOT NULL,
    priority INTEGER NOT NULL DEFAULT 0,
    due INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS pending_due ON pending(due, priority);
CREATE TABLE IF NOT EXISTS state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    root TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0,
    processed INTEGER NOT NULL DEFAULT 0,
    baseline INTEGER NOT NULL DEFAULT 0,
    started INTEGER NOT NULL DEFAULT 0,
    last_update INTEGER NOT NULL DEFAULT 0,
    recovery_cursor INTEGER,
    recovery_again INTEGER NOT NULL DEFAULT 0,
    audit_cursor INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS samples (
    hour INTEGER PRIMARY KEY,
    capacity INTEGER NOT NULL,
    free INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS growth (
    id INTEGER PRIMARY KEY,
    entry INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    hour INTEGER NOT NULL,
    bytes INTEGER NOT NULL,
    UNIQUE(entry, hour)
);
CREATE INDEX IF NOT EXISTS growth_hour ON growth(hour);
CREATE TRIGGER IF NOT EXISTS growth_bound AFTER INSERT ON growth WHEN new.id % 512 = 0 BEGIN
    DELETE FROM growth WHERE id <= new.id - 65536;
END;
CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(
    name_key, content='entries', content_rowid='id', tokenize='trigram', detail=none, columnsize=0
);
CREATE TRIGGER IF NOT EXISTS names_insert AFTER INSERT ON entries BEGIN
    INSERT INTO names(rowid,name_key) VALUES(new.id,new.name_key);
END;
CREATE TRIGGER IF NOT EXISTS names_delete AFTER DELETE ON entries BEGIN
    INSERT INTO names(names,rowid,name_key) VALUES('delete',old.id,old.name_key);
END;
";

pub(crate) fn writer(support: &Path, root: &Path) -> Result<Connection> {
    let mut db = Connection::open(support.join(DATABASE))?;
    db.busy_timeout(Duration::from_secs(3))?;
    db.execute_batch(
        "
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        PRAGMA synchronous = NORMAL;
        PRAGMA wal_autocheckpoint = 512;
        PRAGMA journal_size_limit = 8388608;
        PRAGMA cache_size = -8192;
    ",
    )?;
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    if version > 1 {
        bail!("This index requires a newer version of SpaceTrail.");
    }
    let tx = db.transaction()?;
    if version == 0 {
        tx.execute_batch(SCHEMA)?;
        tx.pragma_update(None, "user_version", 1)?;
    }
    let previous: Option<String> = tx
        .query_row("SELECT root FROM state WHERE id=1", [], |r| r.get(0))
        .optional()?;
    let path = root
        .to_str()
        .context("The selected folder has an invalid path")?;
    if previous.as_deref() != Some(path) {
        tx.execute_batch("DELETE FROM entries; DELETE FROM samples; DELETE FROM state;")?;
        tx.execute("INSERT INTO state(id, root) VALUES(1, ?)", [path])?;
        let id = tx.query_row(
            "INSERT INTO entries(name,name_key,directory) VALUES (?1,?2,?3) RETURNING id",
            params![
                display_path(root),
                crate::fold_name(&display_path(root)),
                path
            ],
            |r| r.get(0),
        )?;
        queue(&tx, id, true, false)?;
    }
    tx.commit()?;
    Ok(db)
}

pub(crate) fn queue(db: &Connection, id: i64, walk: bool, urgent: bool) -> Result<()> {
    db.execute(
        "INSERT INTO pending(directory, walk, priority) VALUES(?,?,?)
         ON CONFLICT(directory) DO UPDATE SET walk=max(walk,excluded.walk),
         priority=max(priority,excluded.priority), due=0",
        params![id, walk, urgent],
    )?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct Totals {
    pub logical: i64,
    pub allocated: i64,
    pub files: i64,
    pub estimates: i64,
}

impl Totals {
    pub fn diff(self, before: Self) -> Self {
        Self {
            logical: self.logical - before.logical,
            allocated: self.allocated - before.allocated,
            files: self.files - before.files,
            estimates: self.estimates - before.estimates,
        }
    }

    pub fn add(&mut self, other: Self) {
        self.logical += other.logical;
        self.allocated += other.allocated;
        self.files += other.files;
        self.estimates += other.estimates;
    }
}

pub(crate) fn adjust(db: &Connection, id: i64, by: Totals) -> Result<()> {
    if by != Totals::default() {
        db.execute(
            "WITH RECURSIVE parents(id) AS (
                 SELECT ?1 UNION ALL
                 SELECT entries.parent FROM entries JOIN parents USING(id) WHERE entries.parent IS NOT NULL
             )
             UPDATE entries SET logical=logical+?2,allocated=allocated+?3,files=files+?4,estimates=estimates+?5
             WHERE id IN parents",
            params![id, by.logical, by.allocated, by.files, by.estimates],
        )?;
    }
    Ok(())
}

pub(crate) fn sample(db: &Connection, space: Capacity) -> Result<()> {
    let hour = now() / 3_600 * 3_600;
    db.execute(
        "INSERT OR REPLACE INTO samples VALUES (?,?,?)",
        params![hour, space.total, space.free],
    )?;
    let cutoff = hour - 90 * 86_400;
    db.execute("DELETE FROM samples WHERE hour < ?", [cutoff])?;
    db.execute("DELETE FROM growth WHERE hour < ?", [cutoff])?;
    Ok(())
}

pub(crate) fn revision(db: &Connection) -> Result<()> {
    db.execute(
        "UPDATE state SET revision=revision+1,last_update=? WHERE id=1",
        [now()],
    )?;
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Entry {
    pub id: i64,
    pub name: String,
    #[serde(serialize_with = "serialize_path")]
    pub path: PathBuf,
    pub folder: bool,
    pub logical: i64,
    pub allocated: i64,
    pub files: i64,
    pub estimated: bool,
    pub modified: i64,
    pub growth: i64,
}

fn serialize_path<S: Serializer>(path: &Path, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&display_path(path))
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Sort {
    Name,
    #[default]
    Disk,
    Logical,
    Modified,
}

impl Sort {
    fn column(self) -> &'static str {
        match self {
            Self::Name => "name_key",
            Self::Disk => "allocated",
            Self::Logical => "logical",
            Self::Modified => "modified",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Request {
    pub folder: Option<i64>,
    pub include_folders: bool,
    pub hide_system: bool,
    pub query: String,
    pub extensions: Vec<String>,
    pub sort: Sort,
    pub ascending: bool,
    pub offset: usize,
}

#[derive(Debug)]
pub struct Page {
    pub rows: Vec<Entry>,
    pub more: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub root: PathBuf,
    pub root_id: i64,
    pub revision: i64,
    pub indexed: i64,
    pub processed: i64,
    pub baseline: bool,
    pub started: i64,
    pub blocked: i64,
    pub pending: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct Sample {
    pub hour: i64,
    pub capacity: i64,
    pub free: i64,
}

#[derive(Debug, Serialize)]
pub struct Storage {
    pub history: Vec<Sample>,
    pub largest: Vec<Entry>,
    pub folders: Vec<Entry>,
    pub recent: Vec<Entry>,
}

pub struct Reader {
    db: Connection,
}

impl Reader {
    pub fn open(support: &Path) -> Result<Option<Self>> {
        let path = support.join(DATABASE);
        if !path.is_file() {
            return Ok(None);
        }
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        db.busy_timeout(Duration::from_millis(600))?;
        if db.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))? == 0 {
            return Ok(None);
        }
        db.pragma_update(None, "cache_size", -4096)?;
        Ok(Some(Self { db }))
    }

    pub fn status(&self) -> Result<Option<Status>> {
        Ok(self
            .db
            .query_row(
                "SELECT s.root,e.id,s.revision,e.files,s.processed,s.baseline,s.started,
                    EXISTS(SELECT 1 FROM pending) OR s.recovery_cursor IS NOT NULL,
                    (SELECT count(*) FROM entries WHERE blocked=1 AND directory IS NOT NULL)
             FROM state s JOIN entries e ON e.directory=s.root WHERE s.id=1",
                [],
                |r| {
                    Ok(Status {
                        root: PathBuf::from(r.get::<_, String>(0)?),
                        root_id: r.get(1)?,
                        revision: r.get(2)?,
                        indexed: r.get(3)?,
                        processed: r.get(4)?,
                        baseline: r.get(5)?,
                        started: r.get(6)?,
                        pending: r.get(7)?,
                        blocked: r.get(8)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn page(&self, request: &Request) -> Result<Page> {
        let (mut rows, more) = self.read_page(request, PAGE_SIZE)?;
        rows.truncate(PAGE_SIZE);
        Ok(Page { rows, more })
    }

    fn read_page(&self, request: &Request, limit: usize) -> Result<(Vec<Entry>, bool)> {
        let mut from = "entries e";
        let mut conditions = vec!["e.parent IS NOT NULL".to_owned()];
        let mut args: Vec<Value> = Vec::new();
        if let Some(folder) = request.folder {
            conditions.push("e.parent=?".to_owned());
            args.push(folder.into());
        } else if !request.include_folders {
            conditions.push("e.directory IS NULL".to_owned());
        }
        let query = crate::fold_name(request.query.trim());
        if query.chars().count() >= 3 {
            // Quote every trigram so user text never becomes FTS syntax.
            let chars: Vec<_> = query.chars().collect();
            let fts = chars
                .windows(3)
                .take(32)
                .map(|part| {
                    let term = part.iter().collect::<String>();
                    format!("\"{}\"", term.replace('"', "\"\""))
                })
                .collect::<Vec<_>>()
                .join(" AND ");
            from = "names CROSS JOIN entries e ON e.id=names.rowid";
            conditions.extend([
                "names MATCH ?".to_owned(),
                "instr(e.name_key,?)>0".to_owned(),
            ]);
            args.extend([fts.into(), query.into()]);
        } else if !query.is_empty() {
            conditions.push("e.name_key>=? AND e.name_key<?".to_owned());
            args.extend([query.clone().into(), format!("{query}{}", char::MAX).into()]);
        }
        if !request.extensions.is_empty() {
            let mut filters = Vec::new();
            for extension in &request.extensions {
                let extension = crate::fold_name(extension.trim_start_matches('.'));
                if let Some((_, last)) = extension.rsplit_once('.') {
                    let suffix = format!(".{extension}");
                    filters.push("(e.extension=? AND substr(e.name_key,-length(?))=?)");
                    args.extend([last.to_owned().into(), suffix.clone().into(), suffix.into()]);
                } else {
                    filters.push("e.extension=?");
                    args.push(extension.into());
                }
            }
            conditions.push("e.directory IS NULL".to_owned());
            conditions.push(format!("({})", filters.join(" OR ")));
        }
        if request.hide_system {
            self.hide_system_fields(&mut conditions, &mut args)?;
        }
        args.extend([(limit as i64 + 1).into(), (request.offset as i64).into()]);
        let predicate = conditions.join(" AND ");
        let order = request.sort.column();
        let direction = if request.ascending { "ASC" } else { "DESC" };
        let sql = format!(
            "WITH chosen AS MATERIALIZED (
                SELECT e.* FROM {from} WHERE {predicate} ORDER BY e.{order} {direction},e.id {direction} LIMIT ? OFFSET ?
             )
             SELECT c.id,c.name,c.directory,c.logical,c.allocated,c.files,c.estimates,c.modified,
                    p.directory,0
             FROM chosen c LEFT JOIN entries p ON p.id=c.parent ORDER BY c.{order} {direction},c.id {direction}"
        );
        let mut stmt = self.db.prepare(&sql)?;
        let records = stmt.query_map(params_from_iter(args), read_entry)?;
        let rows = records.collect::<rusqlite::Result<Vec<_>>>()?;
        let more = rows.len() > limit;
        Ok((rows, more))
    }

    pub fn locate_directory(&self, id: i64) -> Result<Option<(PathBuf, Option<i64>)>> {
        Ok(self
            .db
            .query_row(
                "SELECT directory,parent FROM entries WHERE id=? AND directory IS NOT NULL",
                [id],
                |row| Ok((PathBuf::from(row.get::<_, String>(0)?), row.get(1)?)),
            )
            .optional()?)
    }

    pub fn storage(&self, days: i64) -> Result<Storage> {
        let since = now() / 3_600 * 3_600 - days.clamp(1, 90) * 86_400;
        let history = self
            .db
            .prepare("SELECT hour,capacity,free FROM samples WHERE hour>=? ORDER BY hour")?
            .query_map([since], |r| {
                Ok(Sample {
                    hour: r.get(0)?,
                    capacity: r.get(1)?,
                    free: r.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let (mut largest, _) = self.read_page(
            &Request {
                hide_system: true,
                ..Default::default()
            },
            8,
        )?;
        largest.truncate(8);
        let mut chosen: Vec<Entry> = Vec::new();
        let root: Option<String> = self
            .db
            .query_row("SELECT root FROM state WHERE id=1", [], |r| r.get(0))
            .optional()?;
        if let Some(root) = root {
            let mut stmt = self.db.prepare(
                "SELECT e.id,e.name,e.directory,e.logical,e.allocated,e.files,e.estimates,e.modified,
                        NULL,0 FROM entries e WHERE e.directory IS NOT NULL AND e.parent IS NOT NULL
                        AND e.allocated>0 ORDER BY e.allocated DESC,e.id DESC LIMIT 4096"
            )?;
            let mut rows = stmt.query_map([], read_entry)?;
            for row in &mut rows {
                let entry = row?;
                if specific_folder(Path::new(&root), &entry.path)
                    && !chosen.iter().any(|other| {
                        entry.path.starts_with(&other.path) || other.path.starts_with(&entry.path)
                    })
                {
                    chosen.push(entry);
                    if chosen.len() == 8 {
                        break;
                    }
                }
            }
        }
        let mut conditions = vec!["e.parent IS NOT NULL".to_owned()];
        let mut args = vec![since.into()];
        self.hide_system_fields(&mut conditions, &mut args)?;
        let predicate = conditions.join(" AND ");
        let recent = self.db.prepare(&format!(
            "WITH changes AS MATERIALIZED (
                SELECT entry,sum(bytes) AS delta FROM growth WHERE hour>=? GROUP BY entry HAVING sum(bytes)>0
             ), ranked AS MATERIALIZED (
                SELECT e.*,c.delta FROM changes c CROSS JOIN entries e NOT INDEXED ON e.id=c.entry
                WHERE {predicate} ORDER BY c.delta DESC,e.id DESC LIMIT 8
             )
             SELECT e.id,e.name,e.directory,e.logical,e.allocated,e.files,e.estimates,e.modified,
                    p.directory,e.delta FROM ranked e LEFT JOIN entries p ON p.id=e.parent
             ORDER BY e.delta DESC,e.id DESC",
        ))?.query_map(params_from_iter(args), read_entry)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Storage {
            history,
            largest,
            folders: chosen,
            recent,
        })
    }

    fn hide_system_fields(
        &self,
        predicates: &mut Vec<String>,
        args: &mut Vec<Value>,
    ) -> Result<()> {
        let root: Option<(i64, String)> = self.db.query_row(
            "SELECT e.id,e.directory FROM state s JOIN entries e ON e.directory=s.root WHERE s.id=1",
            [], |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        let Some((id, path)) = root.filter(|(_, path)| is_drive_root(Path::new(path))) else {
            return Ok(());
        };
        predicates.push(
            "(e.parent<>? OR e.name_key NOT IN ('pagefile.sys','hiberfil.sys',
            'swapfile.sys','dumpstack.log','dumpstack.log.tmp','memory.dmp'))"
                .into(),
        );
        args.push(id.into());
        let mut statement = self.db.prepare(
            "SELECT id,directory FROM entries WHERE parent=? AND directory IS NOT NULL
             AND name_key IN ('windows','system volume information','$recycle.bin','recovery','boot','efi')",
        )?;
        let roots = statement.query_map([id], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?;
        for root in roots {
            let (id, directory) = root?;
            predicates.push(
                "e.id<>? AND e.parent<>? AND e.parent NOT IN (
                SELECT id FROM entries WHERE directory>=? AND directory<?
            )"
                .into(),
            );
            // A backslash is followed by ']' in SQLite's binary text collation.
            // This range reads only descendant folders from the directory index.
            args.extend([
                id.into(),
                id.into(),
                format!("{directory}\\").into(),
                format!("{directory}]").into(),
            ]);
        }
        Ok(())
    }
}

fn is_drive_root(path: &Path) -> bool {
    use std::path::{Component, Prefix};
    matches!(path.components().next(),
        Some(Component::Prefix(prefix)) if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
    ) && path.has_root()
        && path.parent().is_none()
}

fn specific_folder(root: &Path, path: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else {
        return false;
    };
    let mut parts = relative.components();
    let first = parts
        .next()
        .map(|p| p.as_os_str().to_string_lossy().to_lowercase());
    match first.as_deref() {
        Some(
            "windows" | "system volume information" | "$recycle.bin" | "recovery" | "boot" | "efi",
        ) => false,
        Some("users") => parts.count() >= 2,
        Some("program files" | "program files (x86)" | "programdata") => parts.next().is_some(),
        Some(_) => true,
        None => false,
    }
}

fn read_entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<Entry> {
    let name: String = row.get(1)?;
    let directory: Option<String> = row.get(2)?;
    let folder = directory.is_some();
    let path = match directory {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(row.get::<_, String>(8)?).join(&name),
    };
    Ok(Entry {
        id: row.get(0)?,
        name,
        path,
        folder,
        logical: row.get(3)?,
        allocated: row.get(4)?,
        files: row.get(5)?,
        estimated: row.get::<_, i64>(6)? > 0,
        modified: row.get(7)?,
        growth: row.get(9)?,
    })
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn default_desktop_rankings_skip_windows_files_but_keep_neighboring_folders() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(SCHEMA).unwrap();
        db.execute_batch(
            r"
            INSERT INTO state(id,root) VALUES(1,'C:\');
            INSERT INTO entries(id,parent,name,name_key,directory,allocated) VALUES
                (1,NULL,'C:\','c:\','C:\',0),
                (2,1,'WINDOWS','windows','C:\WINDOWS',9000),
                (3,2,'System32','system32','C:\WINDOWS\System32',9000),
                (4,1,'Windows Work','windows work','C:\Windows Work',5500),
                (5,3,'large-file.bin','large-file.bin',NULL,9000),
                (6,1,'hiberfil.sys','hiberfil.sys',NULL,7500),
                (7,4,'large-file.txt','large-file.txt',NULL,5500);
        ",
        )
        .unwrap();
        db.execute(
            "INSERT INTO growth(entry,hour,bytes) VALUES(5,?1,9000),(7,?1,5500)",
            [now()],
        )
        .unwrap();
        let reader = Reader { db };
        let request = Request {
            query: "large-file".into(),
            hide_system: true,
            ..Default::default()
        };
        let filtered = reader.page(&request).unwrap();
        assert_eq!(
            filtered.rows.iter().map(|row| row.id).collect::<Vec<_>>(),
            vec![7]
        );
        let unfiltered = reader
            .page(&Request {
                hide_system: false,
                ..request
            })
            .unwrap();
        assert_eq!(unfiltered.rows.len(), 2);
        let storage = reader.storage(7).unwrap();
        assert_eq!(
            storage.largest.iter().map(|row| row.id).collect::<Vec<_>>(),
            vec![7]
        );
        assert_eq!(
            storage.recent.iter().map(|row| row.id).collect::<Vec<_>>(),
            vec![7]
        );
    }
}

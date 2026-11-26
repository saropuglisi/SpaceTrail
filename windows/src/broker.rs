use crate::{
    Settings,
    index::{queue, revision, sample, writer},
    now, platform, scan,
};
use anyhow::{Context, Result};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions, TryLockError},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver},
    },
    time::{Duration, Instant},
};

const EVENT_LIMIT: usize = 512;
const AUDIT_BATCH: i64 = 24;

fn lock_file(support: &Path, name: &str) -> Result<File> {
    fs::create_dir_all(support)?;
    Ok(OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(support.join(name))?)
}

pub fn claim(support: &Path, name: &str) -> Result<Option<File>> {
    let file = lock_file(support, name)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error.into()),
    }
}

pub fn running(support: &Path) -> bool {
    matches!(claim(support, "broker.lock"), Ok(None))
}

pub fn scan_once(support: &Path, root: &Path) -> Result<()> {
    let _lock =
        claim(support, "broker.lock")?.context("SpaceTrail is already indexing this location")?;
    let root = root.canonicalize()?;
    let support = support.canonicalize()?;
    if root.starts_with(&support) {
        anyhow::bail!("Select a location outside SpaceTrail’s index folder.");
    }
    let mut db = writer(&support, &root)?;
    start_recovery(&db)?;
    let stop = AtomicBool::new(false);
    loop {
        advance_recovery(&mut db)?;
        if !scan::step(&mut db, &support, &stop)? && !recovering(&db)? {
            break;
        }
    }
    finish_first_scan(&db)?;
    record_capacity(&db, &root)?;
    Ok(())
}

pub fn run(support: &Path, stop: Arc<AtomicBool>) -> Result<()> {
    let Some(_lock) = claim(support, "broker.lock")? else {
        return Ok(());
    };
    let support = support.canonicalize()?;
    while !stop.load(Ordering::Relaxed) {
        let Some(settings) = Settings::read(&support)? else {
            return Ok(());
        };
        run_scope(&support, &settings, &stop)?;
    }
    Ok(())
}

fn watch(root: &Path) -> (Option<RecommendedWatcher>, Receiver<Event>, Arc<AtomicBool>) {
    let (send, receive) = mpsc::sync_channel(EVENT_LIMIT);
    let overflow = Arc::new(AtomicBool::new(false));
    let wake = Arc::clone(&overflow);
    let watcher = notify::recommended_watcher(move |event: notify::Result<Event>| match event {
        Ok(event) if !event.need_rescan() => {
            if !matches!(event.kind, EventKind::Access(_)) && send.try_send(event).is_err() {
                wake.store(true, Ordering::Relaxed);
            }
        }
        _ => wake.store(true, Ordering::Relaxed),
    })
    .ok()
    .and_then(|mut watcher| {
        watcher.watch(root, RecursiveMode::Recursive).ok()?;
        Some(watcher)
    });
    (watcher, receive, overflow)
}

fn run_scope(support: &Path, settings: &Settings, stop: &AtomicBool) -> Result<()> {
    let root = &settings.root;
    let mut db = writer(support, root)?;
    let (mut watcher, events, mut overflow) = watch(root);
    let mut receive = events;
    // Work missed while SpaceTrail was stopped is reconciled from the last saved
    // directory index. A lost notification uses the same bounded recovery.
    let has_progress: bool = db.query_row(
        "SELECT baseline OR processed>0 FROM state WHERE id=1",
        [],
        |r| r.get(0),
    )?;
    if has_progress {
        start_recovery(&db)?;
    }
    let mut next_sample = Instant::now();
    let mut next_settings = Instant::now();
    let mut next_fallback = Instant::now() + Duration::from_secs(30);
    let mut next_maintenance = Instant::now() + Duration::from_secs(15 * 60);
    let mut parked_event = None;
    while !stop.load(Ordering::Relaxed) {
        let tick = Instant::now();
        if tick >= next_settings {
            if Settings::read(support)?.as_ref() != Some(settings) {
                return Ok(());
            }
            next_settings = tick + Duration::from_secs(2);
        }
        if tick >= next_sample {
            record_capacity(&db, root)?;
            next_sample = tick + Duration::from_secs(300);
        }
        if tick >= next_fallback && watcher.is_none() {
            (watcher, receive, overflow) = watch(root);
            if !recovering(&db)? {
                start_recovery(&db)?;
            }
            next_fallback = tick + Duration::from_secs(60);
        }
        if overflow.swap(false, Ordering::Relaxed) {
            start_recovery(&db)?;
        }

        let count = schedule_events(&mut db, root, support, parked_event.take(), &receive)?;
        if count == 0 {
            advance_recovery(&mut db)?;
        }
        if tick >= next_maintenance {
            schedule_audit_slice(&mut db)?;
            next_maintenance = tick + Duration::from_secs(15 * 60);
        }
        if scan::step(&mut db, support, stop)? {
            std::thread::sleep(Duration::from_millis(if count > 0 { 2 } else { 12 }));
        } else {
            finish_first_scan(&db)?;
            if watcher.is_some() {
                parked_event = receive.recv_timeout(Duration::from_millis(700)).ok();
            } else {
                std::thread::sleep(Duration::from_millis(700));
            }
        }
    }
    Ok(())
}

fn schedule_events(
    db: &mut Connection,
    root: &Path,
    support: &Path,
    first: Option<Event>,
    rx: &Receiver<Event>,
) -> Result<usize> {
    let mut paths = BTreeMap::new();
    let mut seen = 0;
    for event in first.into_iter().chain(rx.try_iter()).take(EVENT_LIMIT) {
        let rename = matches!(
            event.kind,
            EventKind::Modify(notify::event::ModifyKind::Name(_))
        );
        let walk = rename || matches!(event.kind, EventKind::Create(_));
        for path in event.paths {
            let path = if path.starts_with(root) {
                path
            } else if let Ok(suffix) =
                Path::new(&crate::display_path(&path)).strip_prefix(crate::display_path(root))
            {
                root.join(suffix)
            } else {
                continue;
            };
            if scan::excluded(&path, support) {
                continue;
            }
            let flags = (walk, rename);
            paths
                .entry(path)
                .and_modify(|old: &mut (bool, bool)| {
                    old.0 |= flags.0;
                    old.1 |= flags.1;
                })
                .or_insert(flags);
        }
        seen += 1;
    }
    if paths.is_empty() {
        return Ok(seen);
    }
    // A detached startup drive can make its children appear missing. Preserve
    // the saved snapshot until the root is available again.
    if !root.is_dir() {
        return Ok(seen);
    }
    let tx = db.transaction()?;
    for (path, (walk, rename)) in paths {
        let parent = path
            .parent()
            .filter(|p| p.starts_with(root))
            .unwrap_or(root);
        let Some(id) = known_ancestor(&tx, root, parent)? else {
            continue;
        };
        let exact: bool = tx.query_row(
            "SELECT directory=? FROM entries WHERE id=?",
            params![parent.to_str(), id],
            |r| r.get(0),
        )?;
        let refreshed = path != root && exact && scan::refresh_path(&tx, id, &path, support, walk)?;
        // Directory enumeration also drops obsolete case variants after a rename on NTFS.
        if !refreshed || rename {
            queue(&tx, id, false, true)?;
        }
    }
    revision(&tx)?;
    tx.commit()?;
    Ok(seen)
}

fn known_ancestor(db: &Connection, root: &Path, directory: &Path) -> Result<Option<i64>> {
    let mut stmt = db.prepare_cached("SELECT id FROM entries WHERE directory=?")?;
    for path in directory.ancestors().take_while(|p| p.starts_with(root)) {
        if let Some(path) = path.to_str() {
            let id = stmt.query_row([path], |r| r.get(0)).optional()?;
            if id.is_some() {
                return Ok(id);
            }
        }
    }
    Ok(None)
}

fn recovering(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT recovery_cursor IS NOT NULL FROM state WHERE id=1",
        [],
        |r| r.get(0),
    )?)
}

fn start_recovery(db: &Connection) -> Result<()> {
    db.execute(
        "UPDATE state SET recovery_again=recovery_cursor IS NOT NULL,
               recovery_cursor=coalesce(recovery_cursor,0) WHERE id=1",
        [],
    )?;
    Ok(())
}

fn advance_recovery(db: &mut Connection) -> Result<()> {
    let cursor: Option<i64> =
        db.query_row("SELECT recovery_cursor FROM state WHERE id=1", [], |r| {
            r.get(0)
        })?;
    let Some(cursor) = cursor else {
        return Ok(());
    };
    let queued: i64 = db.query_row("SELECT count(*) FROM pending WHERE due<=?", [now()], |r| {
        r.get(0)
    })?;
    if queued >= AUDIT_BATCH {
        return Ok(());
    }
    let tx = db.transaction()?;
    let ids = directory_slice(&tx, cursor)?;
    for id in &ids {
        tx.execute(
            "INSERT OR IGNORE INTO pending(directory,walk) VALUES(?,0)",
            [id],
        )?;
    }
    if let Some(last) = ids.last() {
        tx.execute("UPDATE state SET recovery_cursor=? WHERE id=1", [last])?;
    } else {
        tx.execute(
            "UPDATE state SET recovery_cursor=CASE WHEN recovery_again=1 THEN 0 END,
                    recovery_again=0 WHERE id=1",
            [],
        )?;
    }
    tx.commit()?;
    Ok(())
}

fn directory_slice(db: &Connection, after: i64) -> Result<Vec<i64>> {
    Ok(db
        .prepare("SELECT id FROM entries WHERE id>? AND directory IS NOT NULL ORDER BY id LIMIT ?")?
        .query_map(params![after, AUDIT_BATCH], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?)
}

fn schedule_audit_slice(db: &mut Connection) -> Result<()> {
    let tx = db.transaction()?;
    let cursor = tx.query_row("SELECT audit_cursor FROM state WHERE id=1", [], |r| {
        r.get(0)
    })?;
    let ids = directory_slice(&tx, cursor)?;
    for id in &ids {
        tx.execute(
            "INSERT OR IGNORE INTO pending(directory,walk) VALUES(?,0)",
            [id],
        )?;
    }
    tx.execute(
        "UPDATE state SET audit_cursor=? WHERE id=1",
        [ids.last().copied().unwrap_or(0)],
    )?;
    tx.commit()?;
    Ok(())
}

fn finish_first_scan(db: &Connection) -> Result<()> {
    if db.execute(
        "UPDATE state SET baseline=1,started=? WHERE id=1 AND NOT baseline
                   AND NOT EXISTS(SELECT 1 FROM pending WHERE due<=?)
                   AND NOT EXISTS(SELECT 1 FROM entries WHERE parent IS NULL AND blocked=1)",
        params![now(), now()],
    )? > 0
    {
        revision(db)?;
    }
    Ok(())
}

fn record_capacity(db: &Connection, root: &Path) -> Result<()> {
    if let Some(space) = platform::capacity(root) {
        sample(db, space)?;
        revision(db)?;
    }
    Ok(())
}

pub fn broker_diagnostics(support: &Path) -> Result<PathBuf> {
    fs::create_dir_all(support)?;
    Ok(support.join("broker-error.txt"))
}

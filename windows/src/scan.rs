use crate::{
    index::{Totals, adjust, queue, revision},
    now, platform, seconds,
};
use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    fs, io,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
};

const BATCH: usize = 384;
const RETRY_SECONDS: i64 = 120;

#[derive(Debug)]
struct Item {
    path: PathBuf,
    name: String,
    folder: bool,
    totals: Totals,
    modified: i64,
    created: i64,
}

pub(crate) fn step(db: &mut Connection, support: &Path, stop: &AtomicBool) -> Result<bool> {
    let job: Option<(i64, PathBuf, bool)> = db
        .query_row(
            "SELECT e.id,e.directory,p.walk FROM pending p JOIN entries e ON e.id=p.directory
         WHERE p.due<=? ORDER BY p.priority DESC,p.due,e.id LIMIT 1",
            [now()],
            |row| {
                Ok((
                    row.get(0)?,
                    PathBuf::from(row.get::<_, String>(1)?),
                    row.get(2)?,
                ))
            },
        )
        .optional()?;
    let Some((id, directory, walk)) = job else {
        return Ok(false);
    };
    scan_directory(db, id, &directory, walk, support, stop)?;
    Ok(true)
}

fn scan_directory(
    db: &mut Connection,
    id: i64,
    path: &Path,
    walk: bool,
    support: &Path,
    stop: &AtomicBool,
) -> Result<()> {
    let children = fs::symlink_metadata(path).and_then(|meta| {
        if meta.is_dir() && !platform::is_reparse(&meta) {
            fs::read_dir(path)
        } else {
            Err(io::Error::from(io::ErrorKind::NotADirectory))
        }
    });
    let children = match children {
        Ok(children) => children,
        Err(error) => return unavailable(db, id, &error),
    };

    // The queue entry survives each commit. Restarting a partially scanned folder
    // revisits it with a new generation and reconciles stale names only at the end.
    let generation = db.query_row(
        "UPDATE state SET generation=generation+1 WHERE id=1 RETURNING generation",
        [],
        |r| r.get::<_, i64>(0),
    )?;
    let started: i64 = db.query_row("SELECT started FROM state WHERE id=1", [], |r| r.get(0))?;
    let mut complete = true;
    let mut batch = Vec::with_capacity(BATCH);
    for child in children {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        match child {
            Ok(child) => {
                if excluded(&child.path(), support) {
                    continue;
                }
                match child.metadata().map(|meta| inspect(child.path(), meta)) {
                    Ok(Some(item)) => batch.push(item),
                    Ok(None) => complete = false,
                    Err(error) if vanished(&error) => (),
                    Err(_) => complete = false,
                }
            }
            Err(_) => complete = false,
        }
        if batch.len() == BATCH {
            store(db, id, generation, started, walk, &batch)?;
            batch.clear();
            std::thread::yield_now();
        }
    }
    if !batch.is_empty() {
        store(db, id, generation, started, walk, &batch)?;
    }
    if complete {
        while !stop.load(Ordering::Relaxed) && prune_unseen(db, id, generation)? {}
    }
    if stop.load(Ordering::Relaxed) {
        return Ok(());
    }
    let tx = db.transaction()?;
    mark_blocked(&tx, id, !complete)?;
    if complete {
        tx.execute("DELETE FROM pending WHERE directory=?", [id])?;
    } else {
        tx.execute(
            "UPDATE pending SET priority=0,due=? WHERE directory=?",
            params![now() + RETRY_SECONDS, id],
        )?;
    }
    revision(&tx)?;
    tx.commit()?;
    Ok(())
}

fn inspect(path: PathBuf, meta: fs::Metadata) -> Option<Item> {
    let name = path.file_name()?.to_str()?.to_owned();
    path.to_str()?;
    let reparse = platform::is_reparse(&meta);
    let folder = meta.is_dir() && !reparse;
    let (allocated, estimated) = if meta.is_file() {
        platform::allocated(&path, &meta)
    } else {
        (0, false)
    };
    let totals = if folder {
        Totals::default()
    } else {
        Totals {
            allocated,
            logical: if meta.is_file() { meta.len() as i64 } else { 0 },
            files: 1,
            estimates: i64::from(estimated),
        }
    };
    Some(Item {
        path,
        name,
        folder,
        totals,
        modified: meta.modified().map_or(0, seconds),
        created: meta.created().map_or(0, seconds),
    })
}

pub(crate) fn refresh_path(
    db: &Connection,
    parent: i64,
    path: &Path,
    support: &Path,
    walk: bool,
) -> Result<bool> {
    if excluded(path, support) {
        return Ok(true);
    }
    let generation = db.query_row("SELECT generation FROM state WHERE id=1", [], |r| r.get(0))?;
    let started = db.query_row("SELECT started FROM state WHERE id=1", [], |r| r.get(0))?;
    match fs::symlink_metadata(path) {
        Ok(meta) => {
            if let Some(item) = inspect(path.to_owned(), meta) {
                store_entries(db, parent, generation, started, walk, &[item])?;
            }
            Ok(true)
        }
        Err(error) if vanished(&error) => {
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                return Ok(true);
            };
            let old = db.prepare_cached(
                "SELECT id,logical,allocated,files,estimates FROM entries WHERE parent=? AND name=?"
            )?.query_row(params![parent,name], |r| Ok((r.get::<_,i64>(0)?, totals(r,1)?))).optional()?;
            if let Some((id, size)) = old {
                db.prepare_cached("DELETE FROM entries WHERE id=?")?
                    .execute([id])?;
                adjust(db, parent, Totals::default().diff(size))?;
            }
            Ok(true)
        }
        Err(_) => Ok(false),
    }
}

pub(crate) fn excluded(path: &Path, support: &Path) -> bool {
    let leaf = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    let volume_metadata = ["$Recycle.Bin", "System Volume Information", ".Trashes"];
    volume_metadata
        .iter()
        .any(|name| leaf.eq_ignore_ascii_case(name))
        || path.starts_with(support)
}

fn store(
    db: &mut Connection,
    parent: i64,
    generation: i64,
    started: i64,
    walk: bool,
    batch: &[Item],
) -> Result<()> {
    let tx = db.transaction()?;
    store_entries(&tx, parent, generation, started, walk, batch)?;
    tx.commit()?;
    Ok(())
}

fn store_entries(
    tx: &Connection,
    parent: i64,
    generation: i64,
    started: i64,
    walk: bool,
    batch: &[Item],
) -> Result<()> {
    let mut delta = Totals::default();
    let hour = now() / 3_600 * 3_600;

    for item in batch {
        let previous = tx.prepare_cached(
            "SELECT id,directory IS NOT NULL,logical,allocated,files,estimates FROM entries WHERE parent=? AND name=?"
        )?.query_row(params![parent,item.name], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, bool>(1)?, totals(row, 2)?))
        }).optional()?;
        let retained = previous.filter(|(_, was_folder, _)| *was_folder == item.folder);
        let old_size = previous.map_or(Totals::default(), |(_, _, totals)| totals);
        let new_size = if item.folder {
            retained.map_or(Totals::default(), |(_, _, totals)| totals)
        } else {
            item.totals
        };
        let entry = if let Some((id, _, _)) = retained {
            tx.prepare_cached(
                "UPDATE entries SET logical=?,allocated=?,files=?,estimates=?,modified=?,seen=? WHERE id=?"
            )?.execute(params![new_size.logical,new_size.allocated,new_size.files,new_size.estimates,item.modified,generation,id])?;
            id
        } else {
            if let Some((id, _, _)) = previous {
                tx.prepare_cached("DELETE FROM entries WHERE id=?")?
                    .execute([id])?;
            }
            let directory = if item.folder {
                item.path.to_str()
            } else {
                None
            };
            let extension =
                crate::fold_name(item.path.extension().and_then(|e| e.to_str()).unwrap_or(""));
            tx.prepare_cached(
                "INSERT INTO entries(parent,name,name_key,extension,directory,logical,allocated,files,estimates,modified,seen)
                 VALUES(?,?,?,?,?,?,?,?,?,?,?) RETURNING id"
            )?.query_row(params![parent,item.name,crate::fold_name(&item.name),extension,directory,
                                 new_size.logical,new_size.allocated,new_size.files,new_size.estimates,item.modified,generation],
                        |row| row.get(0))?
        };
        delta.add(new_size.diff(old_size));
        if item.folder && (walk || retained.is_none()) {
            queue(tx, entry, walk, false)?;
        }
        let growth = new_size.allocated - old_size.allocated;
        if !item.folder
            && started > 0
            && growth != 0
            && new_size.estimates == 0
            && (retained.is_some() || item.created >= started)
        {
            tx.prepare_cached(
                "INSERT INTO growth(entry,hour,bytes) VALUES(?,?,?) ON CONFLICT(entry,hour)
                 DO UPDATE SET bytes=growth.bytes+excluded.bytes",
            )?
            .execute(params![entry, hour, growth])?;
        }
    }
    adjust(tx, parent, delta)?;
    tx.execute(
        "UPDATE state SET processed=processed+? WHERE id=1 AND NOT baseline",
        [batch.len() as i64],
    )?;
    if delta != Totals::default() {
        revision(tx)?;
    }
    Ok(())
}

fn totals(row: &rusqlite::Row<'_>, offset: usize) -> rusqlite::Result<Totals> {
    Ok(Totals {
        logical: row.get(offset)?,
        allocated: row.get(offset + 1)?,
        files: row.get(offset + 2)?,
        estimates: row.get(offset + 3)?,
    })
}

fn prune_unseen(db: &mut Connection, parent: i64, generation: i64) -> Result<bool> {
    let tx = db.transaction()?;
    let stale = tx.prepare(
        "SELECT id,logical,allocated,files,estimates FROM entries WHERE parent=? AND seen<>? LIMIT ?"
    )?.query_map(params![parent,generation,BATCH], |row| Ok((row.get::<_, i64>(0)?,totals(row,1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut delta = Totals::default();
    for (id, old) in &stale {
        tx.prepare_cached("DELETE FROM entries WHERE id=?")?
            .execute([id])?;
        delta.add(Totals::default().diff(*old));
    }
    adjust(&tx, parent, delta)?;
    if !stale.is_empty() {
        revision(&tx)?;
    }
    tx.commit()?;
    Ok(stale.len() == BATCH)
}

fn vanished(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
    )
}

fn unavailable(db: &mut Connection, id: i64, error: &io::Error) -> Result<()> {
    let tx = db.transaction()?;
    let (parent, old) = tx
        .query_row(
            "SELECT parent,logical,allocated,files,estimates FROM entries WHERE id=?",
            [id],
            |r| Ok((r.get::<_, Option<i64>>(0)?, totals(r, 1)?)),
        )
        .context("Read queued directory")?;
    if let Some(parent) = parent.filter(|_| vanished(error)) {
        tx.execute("DELETE FROM entries WHERE id=?", [id])?;
        adjust(&tx, parent, Totals::default().diff(old))?;
    } else {
        mark_blocked(&tx, id, true)?;
        tx.execute(
            "UPDATE pending SET priority=0,due=? WHERE directory=?",
            params![now() + RETRY_SECONDS, id],
        )?;
    }
    revision(&tx)?;
    tx.commit()?;
    Ok(())
}

fn mark_blocked(db: &Connection, id: i64, blocked: bool) -> Result<()> {
    let before: bool = db.query_row("SELECT blocked FROM entries WHERE id=?", [id], |row| {
        row.get(0)
    })?;
    if before != blocked {
        db.execute(
            "UPDATE entries SET blocked=? WHERE id=?",
            params![blocked, id],
        )?;
        adjust(
            db,
            id,
            Totals {
                estimates: if blocked { 1 } else { -1 },
                ..Default::default()
            },
        )?;
    }
    Ok(())
}

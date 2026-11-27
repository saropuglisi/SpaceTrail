use anyhow::Result;
use serde::{Deserialize, Serialize};
use spacetrail::{
    broker,
    catalog::{Catalog, Location, Scope},
    display_path, fold_name,
    index::{Entry, PAGE_SIZE, Reader, Request, Sample, Sort, Status},
    platform::Capacity,
};
use std::{collections::BTreeMap, path::Path};

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub(super) enum Section {
    Files,
    Folders,
    Search,
    Map,
    Storage,
}

#[derive(Clone, Deserialize)]
pub(super) struct View {
    pub id: u64,
    pub section: Section,
    drive: Option<String>,
    folder: Option<i64>,
    history_drive: Option<String>,
    query: String,
    format: String,
    #[serde(default)]
    minimum_file_bytes: i64,
    hide_system: bool,
    sort: Sort,
    ascending: bool,
    offsets: BTreeMap<String, usize>,
    days: i64,
}

pub(super) type Revisions = Vec<(String, Option<i64>)>;

#[derive(Clone)]
pub(super) struct Job {
    pub view: View,
    pub since: Option<Revisions>,
    pub starting: bool,
}

#[derive(Serialize)]
pub(super) struct Item {
    pub drive: String,
    #[serde(flatten)]
    pub entry: Entry,
}

#[derive(Serialize)]
pub(super) struct Folder {
    pub drive: String,
    pub id: i64,
    pub path: String,
    pub parent: Option<i64>,
}

#[derive(Default, Serialize)]
pub(super) struct DriveStorage {
    history: Vec<Sample>,
    pub largest: Vec<Item>,
    pub folders: Vec<Item>,
    pub recent: Vec<Item>,
}

#[derive(Serialize)]
pub(super) struct Data {
    id: u64,
    pub items: Vec<Item>,
    pub folder: Option<Folder>,
    next: Option<BTreeMap<String, usize>>,
    pub storage: Option<DriveStorage>,
}

#[derive(PartialEq, Eq, Serialize)]
pub(super) struct DriveActivity {
    id: String,
    label: String,
    path: String,
    phase: &'static str,
    indexed: i64,
    processed: i64,
    ready: bool,
    blocked: i64,
    capacity: Option<Capacity>,
}

#[derive(PartialEq, Eq, Serialize)]
pub(super) struct Activity {
    scope: &'static str,
    drives: Vec<DriveActivity>,
    paused: bool,
}

pub(super) struct Snapshot {
    pub activity: Activity,
    pub revisions: Revisions,
    pub data: Result<Option<Data>>,
}

struct DriveIndex<'a> {
    location: &'a Location,
    reader: Reader,
    status: Status,
}

impl Snapshot {
    pub fn load(support: &Path, job: &Job) -> Result<Self> {
        let catalog = Catalog::read(support)?;
        let paused = !job.starting
            && (!broker::running(support) || support.join("broker-error.txt").is_file());
        let mut drives = Vec::with_capacity(catalog.locations.len());
        let mut indexes = Vec::new();
        let mut revisions = Vec::new();
        for location in &catalog.locations {
            let mut phase = "unavailable";
            let mut state = None;
            if location.available() {
                phase = "starting";
                match Reader::open(&location.index).and_then(|reader| {
                    let status = reader.as_ref().map(Reader::status).transpose()?.flatten();
                    Ok(reader
                        .zip(status)
                        .filter(|(_, item)| item.root == location.root))
                }) {
                    Ok(Some((reader, status))) => {
                        phase = if !status.baseline {
                            "scanning"
                        } else if status.pending {
                            "updating"
                        } else {
                            "current"
                        };
                        state = Some(status.clone());
                        indexes.push(DriveIndex {
                            location,
                            reader,
                            status,
                        });
                    }
                    Ok(None) => {}
                    Err(_) => phase = "paused",
                }
                if paused || location.index.join("scan-error.txt").is_file() {
                    phase = "paused";
                }
            }
            revisions.push((
                location.id.clone(),
                state.as_ref().map(|status| status.revision),
            ));
            drives.push(DriveActivity {
                id: location.id.clone(),
                label: location.label.clone(),
                path: display_path(&location.root),
                phase,
                capacity: location.capacity,
                indexed: state.as_ref().map_or(0, |status| status.indexed),
                processed: state.as_ref().map_or(0, |status| status.processed),
                ready: state.as_ref().is_some_and(|status| status.baseline),
                blocked: state.as_ref().map_or(0, |status| status.blocked),
            });
        }
        let activity = Activity {
            scope: match catalog.scope {
                Scope::AllDrives => "all_drives",
                Scope::Folder { .. } => "folder",
            },
            drives,
            paused,
        };
        let data = if job.since.as_ref() == Some(&revisions) {
            Ok(None)
        } else {
            load_data(&indexes, &job.view).map(Some)
        };
        Ok(Self {
            activity,
            revisions,
            data,
        })
    }
}

fn items(entries: Vec<Entry>, drive: &str) -> impl Iterator<Item = Item> + '_ {
    entries.into_iter().map(move |entry| Item {
        drive: drive.to_owned(),
        entry,
    })
}

fn format_extensions(format: &str) -> Vec<String> {
    let extensions: &[&str] = match format {
        "pdf" => &["pdf"],
        "image" => &[
            "png", "jpg", "jpeg", "webp", "heic", "gif", "svg", "bmp", "tif", "tiff", "avif",
        ],
        "video" => &["mp4", "mov", "mkv", "avi", "wmv", "webm", "m4v", "mpeg"],
        "audio" => &["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "wma"],
        "document" => &[
            "doc", "docx", "pdf", "rtf", "odt", "txt", "md", "xls", "xlsx", "ppt", "pptx", "csv",
        ],
        "ebook" => &["epub", "mobi", "azw", "azw3"],
        "archive" => &["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst"],
        "installer" => &["msi", "exe", "msix", "appx", "msixbundle", "appxbundle"],
        _ => &[],
    };
    extensions
        .iter()
        .map(|extension| (*extension).to_owned())
        .collect()
}

fn load_data(indexes: &[DriveIndex<'_>], view: &View) -> Result<Data> {
    let mut result = Data {
        id: view.id,
        items: Vec::new(),
        folder: None,
        next: None,
        storage: None,
    };
    let browsing = matches!(view.section, Section::Folders | Section::Map);
    let mut included = indexes.iter().filter(|index| {
        view.drive
            .as_ref()
            .is_none_or(|drive| index.location.id == *drive)
    });
    if view.section == Section::Storage {
        let mut storage = DriveStorage::default();
        let history_drive = view.history_drive.as_deref().or_else(|| {
            included
                .clone()
                .next()
                .map(|index| index.location.id.as_str())
        });
        for index in included {
            let data = index.reader.storage(view.days)?;
            let id = &index.location.id;
            if history_drive == Some(id) {
                storage.history = data.history;
            }
            storage.largest.extend(items(data.largest, id));
            storage.folders.extend(items(data.folders, id));
            storage.recent.extend(items(data.recent, id));
        }
        for list in [&mut storage.largest, &mut storage.folders] {
            list.sort_by_key(|item| std::cmp::Reverse(item.entry.allocated));
            list.truncate(8);
        }
        storage
            .recent
            .sort_by_key(|item| std::cmp::Reverse(item.entry.growth));
        storage.recent.truncate(8);
        result.storage = Some(storage);
        return Ok(result);
    }

    let mut request = Request {
        query: view.query.trim().chars().take(240).collect(),
        extensions: format_extensions(&view.format),
        minimum_file_bytes: if browsing { 0 } else { view.minimum_file_bytes },
        hide_system: view.hide_system && !browsing,
        include_folders: view.section == Section::Search,
        sort: view.sort,
        ascending: view.ascending,
        ..Default::default()
    };
    if view.section == Section::Search
        && request.query.is_empty()
        && request.extensions.is_empty()
        && request.minimum_file_bytes <= 0
    {
        return Ok(result);
    }
    if browsing {
        let Some(index) = included.next() else {
            return Ok(result);
        };
        let root = index.status.root_id;
        let mut id = view.folder.unwrap_or(root);
        let mut directory = index.reader.locate_directory(id)?;
        if directory.is_none() {
            id = root;
            directory = index.reader.locate_directory(root)?;
        }
        result.folder = directory.map(|(path, parent)| Folder {
            drive: index.location.id.clone(),
            id,
            path: display_path(&path),
            parent,
        });
        request.folder = Some(id);
        request.offset = page_offset(view, &index.location.id);
        let page = index.reader.page(&request)?;
        result.items.extend(items(page.rows, &index.location.id));
        if page.more {
            result.next = Some(BTreeMap::from([(
                index.location.id.clone(),
                request.offset + PAGE_SIZE,
            )]));
        }
        return Ok(result);
    }

    // Each index contributes at most one page. Keep a cursor per drive so deep
    // pages don't reload every earlier match from each database.
    let mut more = false;
    for index in included {
        request.offset = page_offset(view, &index.location.id);
        let page = index.reader.page(&request)?;
        result.items.extend(items(page.rows, &index.location.id));
        more |= page.more;
    }
    result.next = merge_page(&mut result.items, view, more);
    Ok(result)
}

fn page_offset(view: &View, drive: &str) -> usize {
    view.offsets
        .get(drive)
        .copied()
        .unwrap_or(0)
        .min(20_000_000)
}

fn merge_page(items: &mut Vec<Item>, view: &View, more: bool) -> Option<BTreeMap<String, usize>> {
    if view.sort == Sort::Name {
        items.sort_by_cached_key(|item| {
            (
                fold_name(&item.entry.name),
                item.entry.id,
                item.drive.clone(),
            )
        });
    } else {
        items.sort_by(|a, b| {
            let value = |entry: &Entry| match view.sort {
                Sort::Disk => entry.allocated,
                Sort::Logical => entry.logical,
                Sort::Modified => entry.modified,
                Sort::Name => unreachable!(),
            };
            value(&a.entry)
                .cmp(&value(&b.entry))
                .then(a.entry.id.cmp(&b.entry.id))
                .then(a.drive.cmp(&b.drive))
        });
    }
    if !view.ascending {
        items.reverse();
    }
    let more = more || items.len() > PAGE_SIZE;
    items.truncate(PAGE_SIZE);
    more.then(|| {
        let mut next = view.offsets.clone();
        for item in items {
            *next.entry(item.drive.clone()).or_insert(0) += 1;
        }
        next
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paging_across_drives_advances_only_consumed_rows() {
        let view = serde_json::from_str::<View>(
            r#"{
            "id":1,"section":"files","query":"","format":"","hide_system":true,
            "sort":"disk","ascending":false,"offsets":{},"days":7
        }"#,
        )
        .unwrap();
        let mut entries: Vec<_> = ["C", "D"]
            .iter()
            .enumerate()
            .flat_map(|(n, drive)| {
                (1..=PAGE_SIZE as i64).map(move |id| Item {
                    drive: (*drive).to_owned(),
                    entry: Entry {
                        id,
                        name: "sample.bin".into(),
                        path: Path::new("sample.bin").to_owned(),
                        folder: false,
                        logical: id,
                        allocated: id * 2 + n as i64,
                        files: 1,
                        estimated: false,
                        modified: 0,
                        growth: 0,
                    },
                })
            })
            .collect();
        let next = merge_page(&mut entries, &view, false).unwrap();
        assert_eq!(
            next,
            BTreeMap::from([("C".to_owned(), 75), ("D".to_owned(), 75)])
        );
        assert_eq!(entries[0].drive, "D");
        assert_eq!(entries[1].drive, "C");
        assert_eq!(entries[0].entry.id, entries[1].entry.id);
        assert_eq!(entries.len(), PAGE_SIZE);
    }
}

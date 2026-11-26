use crate::{
    Settings, display_path,
    index::{Reader, is_drive_root},
    platform::{self, Capacity, FixedVolume},
    readable_root,
};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum Scope {
    AllDrives,
    Folder { root: PathBuf },
}

#[derive(Clone, Debug)]
pub struct Location {
    pub id: String,
    pub label: String,
    pub root: PathBuf,
    pub index: PathBuf,
    pub capacity: Option<Capacity>,
    pub fixed: bool,
}

impl Location {
    pub fn available(&self) -> bool {
        self.capacity.is_some() || !self.fixed && self.root.is_dir()
    }

    pub(crate) fn still_mounted(&self) -> bool {
        if !self.fixed {
            return self.root.is_dir();
        }
        let (_, expected) = self.id.split_once('-').expect("fixed volume id");
        platform::mounted_volume_id(&self.root).as_deref() == Some(expected)
    }
}

pub struct Catalog {
    pub scope: Scope,
    pub locations: Vec<Location>,
}

const SCOPE: &str = "scan-scope.json";
const LEGACY_VOLUME: &str = "legacy-volume";

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

impl Scope {
    pub fn set(support: &Path, folder: Option<&Path>) -> Result<Self> {
        let scope = match folder {
            None => Self::AllDrives,
            Some(path) => Self::Folder {
                root: readable_root(support, path)?,
            },
        };
        fs::create_dir_all(support)?;
        let temporary = support.join("scan-scope.new");
        fs::write(&temporary, serde_json::to_vec(&scope)?)?;
        fs::rename(temporary, support.join(SCOPE))?;
        Ok(scope)
    }
}

impl Catalog {
    pub fn read(support: &Path) -> Result<Self> {
        Self::load(support, false)
    }

    // Only the writer binds the legacy index. The old database can stay in its
    // original directory, including a saved scan that hadn't finished yet.
    pub(crate) fn for_indexer(support: &Path) -> Result<Self> {
        Self::load(support, true)
    }

    fn load(support: &Path, bind_legacy: bool) -> Result<Self> {
        let legacy = Settings::read(support).ok().flatten();
        let scope = match read_optional(&support.join(SCOPE))? {
            Some(bytes) => serde_json::from_slice(&bytes)?,
            None => match &legacy {
                Some(settings) if !is_drive_root(&settings.root) => Scope::Folder {
                    root: settings.root.clone(),
                },
                _ => Scope::AllDrives,
            },
        };
        let locations = match &scope {
            Scope::Folder { root } => {
                let index = if legacy.as_ref().is_some_and(|old| old.root == *root)
                    && read_optional(&support.join(LEGACY_VOLUME))?.is_none()
                {
                    support.to_owned()
                } else {
                    support.join("folder")
                };
                vec![Location {
                    id: "folder".into(),
                    label: root
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_else(|| display_path(root)),
                    root: root.clone(),
                    index,
                    capacity: platform::capacity(root),
                    fixed: false,
                }]
            }
            Scope::AllDrives => drive_locations(
                support,
                platform::fixed_volumes()?,
                legacy.as_ref(),
                bind_legacy,
            )?,
        };
        Ok(Self { scope, locations })
    }
}

fn drive_locations(
    support: &Path,
    volumes: Vec<FixedVolume>,
    legacy: Option<&Settings>,
    bind_legacy: bool,
) -> Result<Vec<Location>> {
    let marker = support.join(LEGACY_VOLUME);
    let mut bound = read_optional(&marker)?.and_then(|data| String::from_utf8(data).ok());
    if bind_legacy
        && bound.is_none()
        && let Some(volume) = matching_legacy_volume(support, &volumes, legacy)
            .ok()
            .flatten()
    {
        let pending = support.join("legacy-volume.new");
        fs::write(&pending, &volume.id)?;
        fs::rename(pending, marker)?;
        bound = Some(volume.id.clone());
    }
    Ok(volumes
        .into_iter()
        .map(|volume| {
            let index = if bound.as_deref() == Some(&volume.id) {
                support.to_owned()
            } else {
                support.join("volumes").join(&volume.id)
            };
            Location {
                id: volume.id,
                label: volume.label,
                root: volume.root,
                index,
                capacity: volume.capacity,
                fixed: true,
            }
        })
        .collect())
}

fn matching_legacy_volume<'a>(
    support: &Path,
    volumes: &'a [FixedVolume],
    legacy: Option<&Settings>,
) -> Result<Option<&'a FixedVolume>> {
    let Some(legacy) = legacy.filter(|old| is_drive_root(&old.root)) else {
        return Ok(None);
    };
    let Some(volume) = volumes.iter().find(|volume| volume.root == legacy.root) else {
        return Ok(None);
    };
    let Some(reader) = Reader::open(support)? else {
        return Ok(None);
    };
    Ok(reader
        .status()?
        .is_some_and(|status| status.root == volume.root)
        .then_some(volume))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_drive_keeps_its_database_when_more_drives_are_discovered() -> Result<()> {
        let support = std::env::temp_dir().join(format!(
            "spacetrail-drive-migration-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos(),
        ));
        fs::create_dir_all(&support)?;
        let outcome = (|| -> Result<()> {
            let old = Settings {
                root: PathBuf::from(r"\\?\C:\"),
            };
            let db = crate::index::writer(&support, &old.root)?;
            db.execute("UPDATE state SET processed=64000 WHERE id=1", [])?;
            drop(db);
            let locations = drive_locations(
                &support,
                vec![
                    FixedVolume {
                        id: "C-example".into(),
                        label: "Local Disk (C:)".into(),
                        root: old.root.clone(),
                        capacity: None,
                    },
                    FixedVolume {
                        id: "D-example".into(),
                        label: "Work (D:)".into(),
                        root: PathBuf::from(r"\\?\D:\"),
                        capacity: None,
                    },
                ],
                Some(&old),
                true,
            )?;
            assert_eq!(locations.len(), 2);
            assert_eq!(locations[0].index, support);
            assert_eq!(
                locations[1].index,
                support.join("volumes").join("D-example")
            );
            let saved = Reader::open(&locations[0].index)?
                .unwrap()
                .status()?
                .unwrap();
            assert_eq!(saved.processed, 64000);
            assert!(!saved.baseline);
            Ok(())
        })();
        let _ = fs::remove_dir_all(support);
        outcome
    }
}

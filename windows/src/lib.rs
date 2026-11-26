pub mod broker;
pub mod index;
pub mod platform;
mod scan;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    pub root: PathBuf,
}

impl Settings {
    pub fn read(support: &Path) -> Result<Option<Self>> {
        match fs::read(support.join("settings.json")) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    pub fn choose(support: &Path, root: &Path) -> Result<Self> {
        let root = root
            .canonicalize()
            .context("Cannot open the selected folder")?;
        if !root.is_dir() || root.to_str().is_none() {
            bail!("Select a readable folder with a valid Windows path.");
        }
        fs::read_dir(&root).context("Cannot list the selected folder")?;
        fs::create_dir_all(support)?;
        let support_path = support.canonicalize()?;
        if root.starts_with(&support_path) {
            bail!("Select a location outside SpaceTrail’s index folder.");
        }
        let settings = Self { root };
        let pending = support.join("settings.json.new");
        fs::write(&pending, serde_json::to_vec(&settings)?)?;
        fs::rename(pending, support.join("settings.json"))?;
        Ok(settings)
    }
}

pub fn now() -> i64 {
    seconds(SystemTime::now())
}

pub fn seconds(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

pub fn format_size(bytes: i64) -> String {
    let bytes = bytes.max(0);
    for (unit, divisor) in [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)] {
        if bytes as f64 >= divisor {
            return format!("{:.1} {unit}", bytes as f64 / divisor);
        }
    }
    format!("{bytes} B")
}

pub fn display_path(path: &Path) -> String {
    let path = path.to_string_lossy();
    if let Some(unc) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{unc}")
    } else {
        path.strip_prefix(r"\\?\").unwrap_or(&path).to_owned()
    }
}

pub(crate) fn fold_name(value: &str) -> String {
    use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};
    value
        .nfkd()
        .filter(|ch| !is_combining_mark(*ch))
        .flat_map(char::to_lowercase)
        .collect()
}

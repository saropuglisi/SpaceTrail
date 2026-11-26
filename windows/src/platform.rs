use std::{fs::Metadata, path::Path};

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Capacity {
    pub total: i64,
    pub free: i64,
}

impl Capacity {
    pub fn used(self) -> i64 {
        (self.total - self.free).max(0)
    }
}

#[cfg(windows)]
pub fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    value.encode_wide().chain([0]).collect()
}

#[cfg(windows)]
pub fn is_reparse(metadata: &Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
pub fn is_reparse(metadata: &Metadata) -> bool {
    metadata.file_type().is_symlink()
}

#[cfg(windows)]
pub fn allocated(path: &Path, metadata: &Metadata) -> (i64, bool) {
    use std::{mem::size_of, ptr::null_mut};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        Storage::FileSystem::*,
    };

    // Open an attribute handle, including when another process is writing or
    // moving the file. OPEN_REPARSE_POINT avoids reading placeholder contents.
    let path = wide(path.as_os_str());
    unsafe {
        let file = CreateFileW(
            path.as_ptr(),
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null_mut(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_OPEN_NO_RECALL,
            null_mut(),
        );
        if file != INVALID_HANDLE_VALUE {
            let mut info = FILE_STANDARD_INFO::default();
            let ok = GetFileInformationByHandleEx(
                file,
                FileStandardInfo,
                (&mut info as *mut FILE_STANDARD_INFO).cast(),
                size_of::<FILE_STANDARD_INFO>() as u32,
            );
            CloseHandle(file);
            if ok != 0 {
                // Shared hard-link allocations are included in these per-path totals.
                return (info.AllocationSize.max(0), info.NumberOfLinks > 1);
            }
        }
    }
    (metadata.len() as i64, true)
}

#[cfg(unix)]
pub fn allocated(_path: &Path, metadata: &Metadata) -> (i64, bool) {
    use std::os::unix::fs::MetadataExt;
    (
        metadata.blocks().saturating_mul(512) as i64,
        metadata.nlink() > 1,
    )
}

#[cfg(windows)]
pub fn capacity(path: &Path) -> Option<Capacity> {
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let path = wide(path.as_os_str());
    let (mut available, mut total, mut free) = (0_u64, 0_u64, 0_u64);
    let ok = unsafe { GetDiskFreeSpaceExW(path.as_ptr(), &mut available, &mut total, &mut free) };
    (ok != 0 && total != 0).then_some(Capacity {
        total: total as i64,
        free: free as i64,
    })
}

#[cfg(not(windows))]
pub fn capacity(_path: &Path) -> Option<Capacity> {
    None
}

#[cfg(windows)]
#[derive(Debug)]
pub(crate) struct FixedVolume {
    pub id: String,
    pub root: std::path::PathBuf,
    pub label: String,
    pub capacity: Option<Capacity>,
}

#[cfg(windows)]
pub(crate) fn fixed_volumes() -> std::io::Result<Vec<FixedVolume>> {
    use std::{collections::BTreeSet, path::PathBuf, ptr::null_mut};
    use windows_sys::Win32::{
        Storage::FileSystem::{GetDriveTypeW, GetLogicalDrives, GetVolumeInformationW},
        System::WindowsProgramming::DRIVE_FIXED,
    };

    let mask = unsafe { GetLogicalDrives() };
    if mask == 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut identified = BTreeSet::new();
    let mut volumes = Vec::new();
    for letter in (b'A'..=b'Z').filter(|letter| mask & (1 << (letter - b'A')) != 0) {
        let drive = format!("{}:\\", char::from(letter));
        let path: Vec<u16> = drive.encode_utf16().chain([0]).collect();
        if unsafe { GetDriveTypeW(path.as_ptr()) } != DRIVE_FIXED {
            continue;
        }
        let root = PathBuf::from(format!(r"\\?\{drive}"));
        let Some(id) = mounted_volume_id(&root) else {
            continue;
        };
        if !identified.insert(id.clone()) {
            continue;
        }
        let mut label = [0_u16; 261];
        let named = unsafe {
            GetVolumeInformationW(
                path.as_ptr(),
                label.as_mut_ptr(),
                label.len() as u32,
                null_mut(),
                null_mut(),
                null_mut(),
                null_mut(),
                0,
            )
        };
        let label = if named != 0 {
            String::from_utf16_lossy(label.split(|unit| *unit == 0).next().unwrap_or(&[]))
        } else {
            String::new()
        };
        let name = if label.trim().is_empty() {
            "Local Disk"
        } else {
            label.trim()
        };
        volumes.push(FixedVolume {
            id: format!("{}-{id}", char::from(letter)),
            label: format!("{name} ({}:)", char::from(letter)),
            capacity: capacity(&root),
            root,
        });
    }
    Ok(volumes)
}

#[cfg(windows)]
pub(crate) fn mounted_volume_id(root: &Path) -> Option<String> {
    use windows_sys::Win32::Storage::FileSystem::GetVolumeNameForVolumeMountPointW;

    let mount: Vec<u16> = crate::display_path(root)
        .encode_utf16()
        .chain([0])
        .collect();
    let mut volume = [0_u16; 64];
    let ok = unsafe {
        GetVolumeNameForVolumeMountPointW(mount.as_ptr(), volume.as_mut_ptr(), volume.len() as u32)
    };
    if ok == 0 {
        return None;
    }
    let name = String::from_utf16_lossy(volume.split(|unit| *unit == 0).next()?);
    let id = name.strip_prefix(r"\\?\Volume{")?.strip_suffix("}\\")?;
    (id.len() == 36
        && id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-'))
    .then(|| id.to_ascii_lowercase())
}

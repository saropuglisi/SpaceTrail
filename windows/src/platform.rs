use std::{fs::Metadata, path::Path};

#[derive(Clone, Copy, Debug)]
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

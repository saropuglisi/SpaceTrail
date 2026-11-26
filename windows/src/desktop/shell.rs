use super::{show_error, text};
use anyhow::{Result, bail};
use spacetrail::{broker, display_path, platform::wide};
use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
    process::Command,
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::*,
    System::{Com::*, Registry::*},
    UI::Shell::*,
};

pub fn spawn(background: bool) -> Result<()> {
    let mut command = Command::new(env::current_exe()?);
    if background {
        command.arg("--broker");
    }
    command.spawn()?;
    Ok(())
}

pub fn ensure_broker(support: &Path) {
    if !broker::running(support)
        && let Err(error) = spawn(true)
    {
        show_error(&format!("Could not start background updates. {error}"));
    }
}

pub fn folder_dialog(owner: HWND) -> Option<PathBuf> {
    let title = text("Choose a drive or folder to index.");
    let mut display = [0_u16; 260];
    unsafe {
        let options = BROWSEINFOW {
            hwndOwner: owner,
            pszDisplayName: display.as_mut_ptr(),
            lpszTitle: title.as_ptr(),
            ulFlags: BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
            ..Default::default()
        };
        let selected = SHBrowseForFolderW(&options);
        if selected.is_null() {
            return None;
        }
        let mut buffer = vec![0_u16; 32_768];
        let ok = SHGetPathFromIDListEx(selected, buffer.as_mut_ptr(), buffer.len() as u32, 0);
        CoTaskMemFree(selected.cast());
        (ok != 0).then(|| {
            use std::os::windows::ffi::OsStringExt;
            let end = buffer
                .iter()
                .position(|unit| *unit == 0)
                .unwrap_or(buffer.len());
            PathBuf::from(OsString::from_wide(&buffer[..end]))
        })
    }
}

pub fn reveal(path: &Path) -> Result<()> {
    let path = text(&display_path(path));
    let mut item = null_mut();
    unsafe {
        let parsed = SHParseDisplayName(path.as_ptr(), null_mut(), &mut item, 0, null_mut());
        if parsed < 0 {
            bail!("Explorer could not find this item.");
        }
        let opened = SHOpenFolderAndSelectItems(item, 0, null(), 0);
        CoTaskMemFree(item.cast());
        if opened < 0 {
            bail!("Explorer could not open this location.");
        }
    }
    Ok(())
}

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "SpaceTrail";

pub fn launch_at_login() -> bool {
    let key = text(RUN_KEY);
    let name = text(RUN_VALUE);
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            name.as_ptr(),
            RRF_RT_REG_SZ,
            null_mut(),
            null_mut(),
            null_mut(),
        ) == ERROR_SUCCESS
    }
}

pub fn set_launch_at_login(enabled: bool) -> Result<()> {
    let key = text(RUN_KEY);
    let name = text(RUN_VALUE);
    unsafe {
        let status = if enabled {
            let mut command = OsString::from("\"");
            command.push(env::current_exe()?);
            command.push("\" --broker");
            let command = wide(&command);
            RegSetKeyValueW(
                HKEY_CURRENT_USER,
                key.as_ptr(),
                name.as_ptr(),
                REG_SZ,
                command.as_ptr().cast(),
                (command.len() * 2) as u32,
            )
        } else {
            RegDeleteKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr())
        };
        if status != ERROR_SUCCESS && (enabled || status != ERROR_FILE_NOT_FOUND) {
            return Err(std::io::Error::from_raw_os_error(status as i32).into());
        }
    }
    Ok(())
}

pub struct Thumbnail(pub usize);

impl Drop for Thumbnail {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Graphics::Gdi::DeleteObject(self.0 as _);
        }
    }
}

pub unsafe fn thumbnail(path: &Path) -> Option<Thumbnail> {
    use std::ffi::c_void;
    use windows_sys::{Win32::Graphics::Gdi::HBITMAP, core::GUID};

    // IShellItemImageFactory has IUnknown's three slots followed by GetImage.
    #[repr(C)]
    struct FactoryVtable {
        query_interface: usize,
        add_ref: usize,
        release: unsafe extern "system" fn(*mut c_void) -> u32,
        image: unsafe extern "system" fn(*mut c_void, SIZE, u32, *mut HBITMAP) -> i32,
    }

    const IID: GUID = GUID::from_u128(0xbcc18b79_ba16_442f_80c4_8a59c30c463b);
    const THUMBNAIL_ONLY: u32 = 0x8;
    // A shell provider may live outside SpaceTrail. Leave placeholder files
    // offline and never try to thumbnail them in the background.
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || spacetrail::platform::is_reparse(&meta) {
        return None;
    }
    let path = text(&display_path(path));
    let mut item = null_mut();
    if SHCreateItemFromParsingName(path.as_ptr(), null_mut(), &IID, &mut item) < 0 || item.is_null()
    {
        return None;
    }
    let vtable = &**(item as *const *const FactoryVtable);
    let mut result = null_mut();
    let status = (vtable.image)(item, SIZE { cx: 168, cy: 192 }, THUMBNAIL_ONLY, &mut result);
    (vtable.release)(item);
    (status >= 0 && !result.is_null()).then_some(Thumbnail(result as usize))
}

pub fn date(seconds: i64) -> String {
    use windows_sys::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTime};
    if seconds == 0 {
        return String::new();
    }
    let ticks = (seconds + 11_644_473_600).saturating_mul(10_000_000) as u64;
    let filetime = FILETIME {
        dwLowDateTime: ticks as u32,
        dwHighDateTime: (ticks >> 32) as u32,
    };
    let mut utc = SYSTEMTIME::default();
    let mut local = SYSTEMTIME::default();
    unsafe {
        if FileTimeToSystemTime(&filetime, &mut utc) == 0
            || SystemTimeToTzSpecificLocalTime(null(), &utc, &mut local) == 0
        {
            return String::new();
        }
    }
    format!("{:04}-{:02}-{:02}", local.wYear, local.wMonth, local.wDay)
}

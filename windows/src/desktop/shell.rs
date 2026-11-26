use super::text;
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

pub fn ensure_broker(support: &Path) -> Result<()> {
    if !broker::running(support) {
        spawn(true)?;
    }
    Ok(())
}

pub fn folder_dialog(owner: HWND) -> Result<Option<PathBuf>> {
    use windows::{
        Win32::{
            Foundation::{ERROR_CANCELLED, HWND as WindowHandle},
            System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance},
            UI::Shell::{
                FOS_FORCEFILESYSTEM, FOS_PATHMUSTEXIST, FOS_PICKFOLDERS, FileOpenDialog,
                IFileOpenDialog, SIGDN_FILESYSPATH,
            },
        },
        core::PCWSTR,
    };
    unsafe {
        let dialog: IFileOpenDialog =
            CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
        dialog.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST)?;
        let title = text("Choose a location to scan");
        dialog.SetTitle(PCWSTR(title.as_ptr()))?;
        if let Err(error) = dialog.Show(Some(WindowHandle(owner))) {
            if error.code() == ERROR_CANCELLED.to_hresult() {
                return Ok(None);
            }
            return Err(error.into());
        }
        let path = dialog.GetResult()?.GetDisplayName(SIGDN_FILESYSPATH)?;
        use std::os::windows::ffi::OsStringExt;
        let selected = PathBuf::from(OsString::from_wide(path.as_wide()));
        CoTaskMemFree(path.0.cast());
        Ok(Some(selected))
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

pub fn prefers_dark() -> bool {
    let key = text(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
    let value = text("AppsUseLightTheme");
    let mut light = 1_u32;
    let mut bytes = std::mem::size_of_val(&light) as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_DWORD,
            null_mut(),
            (&mut light as *mut u32).cast(),
            &mut bytes,
        )
    };
    status == ERROR_SUCCESS && light == 0
}

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

struct Thumbnail(pub windows_sys::Win32::Graphics::Gdi::HBITMAP);

impl Drop for Thumbnail {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Graphics::Gdi::DeleteObject(self.0);
        }
    }
}

unsafe fn thumbnail(path: &Path) -> Option<Thumbnail> {
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
    let status = (vtable.image)(item, SIZE { cx: 320, cy: 300 }, THUMBNAIL_ONLY, &mut result);
    (vtable.release)(item);
    let image = (!result.is_null()).then_some(Thumbnail(result))?;
    (status >= 0).then_some(image)
}

pub fn preview(path: &Path) -> Option<String> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use std::mem::size_of;
    use windows_sys::Win32::Graphics::Gdi::*;

    unsafe {
        let image = thumbnail(path)?;
        let mut bitmap = BITMAP::default();
        let copied = GetObjectW(
            image.0,
            size_of::<BITMAP>() as i32,
            (&mut bitmap as *mut BITMAP).cast(),
        );
        let (width, height) = (bitmap.bmWidth, bitmap.bmHeight);
        if copied == 0 || !(1..=1024).contains(&width) || !(1..=1024).contains(&height) {
            return None;
        }
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB,
                ..Default::default()
            },
            ..Default::default()
        };
        let dc = GetDC(null_mut());
        if dc.is_null() {
            return None;
        }
        let mut pixels = vec![0_u8; (width * height * 4) as usize];
        let copied = GetDIBits(
            dc,
            image.0,
            0,
            height as u32,
            pixels.as_mut_ptr().cast(),
            &mut info,
            DIB_RGB_COLORS,
        );
        ReleaseDC(null_mut(), dc);
        if copied != height {
            return None;
        }
        // Shell providers may return RGB data with an unused alpha channel.
        let has_alpha = pixels.chunks_exact(4).any(|pixel| pixel[3] > 0);
        for pixel in pixels.chunks_exact_mut(4) {
            pixel.swap(0, 2);
            if !has_alpha {
                pixel[3] = 255;
            } else if (1..255).contains(&pixel[3]) {
                let alpha = u16::from(pixel[3]);
                for value in &mut pixel[..3] {
                    *value = ((u16::from(*value) * 255) / alpha).min(255) as u8;
                }
            }
        }
        let mut encoded = Vec::new();
        let mut encoder = png::Encoder::new(&mut encoded, width as u32, height as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder
            .write_header()
            .ok()?
            .write_image_data(&pixels)
            .ok()?;
        Some(format!(
            "data:image/png;base64,{}",
            STANDARD.encode(encoded)
        ))
    }
}

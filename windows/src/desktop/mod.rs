#![allow(unsafe_op_in_unsafe_fn)]

mod shell;
mod tray;
mod window;

use anyhow::{Context, Result};
use spacetrail::platform::wide;
use std::{env, ffi::OsStr, path::PathBuf, ptr::null_mut};
use windows_sys::Win32::{
    Foundation::*, System::LibraryLoader::GetModuleHandleW, UI::WindowsAndMessaging::*,
};

pub fn start_window() -> Result<()> {
    window::run(support()?)
}

pub fn start_broker() -> Result<()> {
    tray::run(support()?)
}

pub fn stop_desktop() -> Result<()> {
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject,
    };
    for class in ["SpaceTrail.Window", "SpaceTrail.Broker"] {
        unsafe {
            let handle = FindWindowW(text(class).as_ptr(), std::ptr::null());
            if handle.is_null() {
                continue;
            }
            let mut pid = 0;
            GetWindowThreadProcessId(handle, &mut pid);
            let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
            if process.is_null() {
                anyhow::ensure!(
                    IsWindow(handle) == 0,
                    "Close SpaceTrail before running setup."
                );
                continue;
            }
            PostMessageW(handle, WM_CLOSE, 0, 0);
            let result = WaitForSingleObject(process, 15_000);
            CloseHandle(process);
            anyhow::ensure!(
                result == WAIT_OBJECT_0,
                "Close SpaceTrail before running setup."
            );
        }
    }
    Ok(())
}

fn support() -> Result<PathBuf> {
    Ok(
        PathBuf::from(env::var_os("LOCALAPPDATA").context("Local AppData is unavailable")?)
            .join("SpaceTrail"),
    )
}

fn text(value: &str) -> Vec<u16> {
    wide(OsStr::new(value))
}

pub fn show_error(message: &str) {
    unsafe {
        MessageBoxW(
            null_mut(),
            text(message).as_ptr(),
            text("SpaceTrail").as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

fn module() -> HINSTANCE {
    unsafe { GetModuleHandleW(std::ptr::null()) }
}

fn icon() -> HICON {
    unsafe { LoadIconW(module(), windows_sys::w!("SPACETRAIL_ICON")) }
}

fn win_result<T>(value: T, success: bool) -> std::io::Result<T> {
    if success {
        Ok(value)
    } else {
        Err(std::io::Error::last_os_error())
    }
}

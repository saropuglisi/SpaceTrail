#![allow(unsafe_op_in_unsafe_fn)]

mod canvas;
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

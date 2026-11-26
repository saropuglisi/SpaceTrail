use super::{icon, module, shell, text, win_result};
use anyhow::Result;
use spacetrail::{broker, catalog::Catalog, format_size};
use std::{
    fs,
    mem::{size_of, zeroed},
    path::PathBuf,
    ptr::{null, null_mut},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};
use windows_sys::Win32::{
    Foundation::*,
    UI::{Shell::*, WindowsAndMessaging::*},
};

const NOTIFY: u32 = WM_APP + 1;

struct Tray {
    support: PathBuf,
    stop: Arc<AtomicBool>,
    message: u32,
}

pub fn run(support: PathBuf) -> Result<()> {
    let Some(_lock) = broker::claim(&support, "tray.lock")? else {
        return Ok(());
    };
    let stop = Arc::new(AtomicBool::new(false));
    let state = Box::new(Tray {
        support: support.clone(),
        stop: Arc::clone(&stop),
        message: unsafe { RegisterWindowMessageW(text("TaskbarCreated").as_ptr()) },
    });
    let state = Box::into_raw(state);
    let class = text("SpaceTrail.Broker");
    unsafe {
        let registration = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: module(),
            lpszClassName: class.as_ptr(),
            ..Default::default()
        };
        let atom = RegisterClassW(&registration);
        if atom == 0 {
            drop(Box::from_raw(state));
            win_result((), false)?;
        }
        let handle = CreateWindowExW(
            0,
            class.as_ptr(),
            text("SpaceTrail Background").as_ptr(),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            null_mut(),
            null_mut(),
            module(),
            state.cast(),
        );
        if handle.is_null() {
            drop(Box::from_raw(state));
            win_result((), false)?;
        }
        let worker = thread::spawn(move || {
            let error_file = support.join("broker-error.txt");
            let _ = fs::remove_file(&error_file);
            let mut retry = 2;
            while !stop.load(Ordering::Relaxed) {
                let began = std::time::Instant::now();
                if let Err(error) = broker::run_catalog(&support, &stop) {
                    let _ = fs::write(&error_file, format!("{error:#}"));
                }
                if began.elapsed() >= Duration::from_secs(30) {
                    retry = 2;
                }
                for _ in 0..retry * 4 {
                    if stop.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(250));
                }
                retry = (retry * 2).min(60);
                let _ = fs::remove_file(&error_file);
            }
        });
        let mut message: MSG = zeroed();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if IsWindow(handle) != 0 {
            DestroyWindow(handle);
        }
        (*state).stop.store(true, Ordering::Relaxed);
        let _ = worker.join();
        drop(Box::from_raw(state));
    }
    Ok(())
}

unsafe extern "system" fn procedure(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = &*(lparam as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
        return 1;
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const Tray;
    let Some(state) = pointer.as_ref() else {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    };
    match message {
        WM_CREATE => {
            add_icon(hwnd);
            0
        }
        NOTIFY => {
            let input = lparam as u32 & 0xffff;
            if input == WM_LBUTTONDBLCLK || input == NIN_SELECT + 1 {
                let _ = shell::spawn(false);
            } else if input == WM_CONTEXTMENU || input == WM_RBUTTONUP || input == WM_LBUTTONUP {
                menu(hwnd, state);
            }
            0
        }
        WM_CLOSE => {
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            Shell_NotifyIconW(NIM_DELETE, &notification(hwnd));
            state.stop.store(true, Ordering::Relaxed);
            PostQuitMessage(0);
            0
        }
        _ if message == state.message => {
            add_icon(hwnd);
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe fn notification(hwnd: HWND) -> NOTIFYICONDATAW {
    let mut data = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP,
        uCallbackMessage: NOTIFY,
        hIcon: icon(),
        ..std::mem::zeroed()
    };
    let tip = text("SpaceTrail");
    data.szTip[..tip.len()].copy_from_slice(&tip);
    data
}

unsafe fn add_icon(hwnd: HWND) {
    let mut data = notification(hwnd);
    if Shell_NotifyIconW(NIM_ADD, &data) != 0 {
        data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
}

unsafe fn menu(hwnd: HWND, state: &Tray) {
    let menu = CreatePopupMenu();
    if menu.is_null() {
        return;
    }
    AppendMenuW(menu, MF_STRING, 1, text("Open SpaceTrail").as_ptr());
    if let Ok(catalog) = Catalog::read(&state.support) {
        for location in catalog.locations {
            if let Some(space) = location.capacity {
                let label = format!("{} · {} free", location.label, format_size(space.free));
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, text(&label).as_ptr());
            }
        }
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, null());
    AppendMenuW(menu, MF_STRING, 2, text("Quit Background Updates").as_ptr());
    let mut point = POINT::default();
    GetCursorPos(&mut point);
    SetForegroundWindow(hwnd);
    let command = TrackPopupMenu(
        menu,
        TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
        point.x,
        point.y,
        0,
        hwnd,
        null(),
    );
    DestroyMenu(menu);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    match command {
        1 => {
            let _ = shell::spawn(false);
        }
        2 => {
            DestroyWindow(hwnd);
        }
        _ => (),
    }
}

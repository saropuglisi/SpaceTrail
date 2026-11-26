use super::{canvas, icon, module, shell, show_error, text, win_result};
use anyhow::{Context, Result};
use spacetrail::{
    Settings, broker, display_path, format_size,
    index::{Entry, PAGE_SIZE, Reader, Request, Sort, Status, Storage},
    platform::{self, Capacity},
};
use std::{
    cell::RefCell,
    env, fs,
    mem::{size_of, zeroed},
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::mpsc::{self, Receiver, Sender},
    thread,
};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    System::{
        Com::*,
        SystemServices::{APPCOMMAND_BROWSER_BACKWARD, APPCOMMAND_BROWSER_FORWARD, SS_NOPREFIX},
    },
    UI::{Controls::*, HiDpi::GetDpiForWindow, Input::KeyboardAndMouse::*, WindowsAndMessaging::*},
};

const DATA_READY: u32 = WM_APP + 1;
const PREVIEW_READY: u32 = WM_APP + 2;
const ID_TABS: u16 = 101;
const ID_QUERY: u16 = 102;
const ID_FORMAT: u16 = 103;
const ID_APPLY: u16 = 104;
const ID_CHOOSE: u16 = 105;
const ID_INDEX: u16 = 106;
const ID_UP: u16 = 107;
const ID_HISTORY_BACK: u16 = 108;
const ID_HISTORY_NEXT: u16 = 109;
const ID_PREV: u16 = 110;
const ID_NEXT: u16 = 111;
const ID_REVEAL: u16 = 112;
const ID_DAYS: u16 = 113;
const ID_RANK: u16 = 114;
const ID_STARTUP: u16 = 115;
const ID_PREVIEW: u16 = 116;
const ID_LIST: u16 = 117;
const ID_FOCUS_SEARCH: u16 = 118;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Section {
    Files,
    Folders,
    Search,
    Map,
    Storage,
}

impl Section {
    const ALL: [Self; 5] = [
        Self::Files,
        Self::Folders,
        Self::Search,
        Self::Map,
        Self::Storage,
    ];

    fn title(self) -> &'static str {
        match self {
            Self::Files => "Files",
            Self::Folders => "Folders",
            Self::Search => "Search",
            Self::Map => "Map",
            Self::Storage => "Storage",
        }
    }

    fn browse(self) -> bool {
        matches!(self, Self::Folders | Self::Map)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Location {
    section: Section,
    folder: Option<i64>,
}

#[derive(Clone)]
struct Job {
    epoch: u64,
    root: PathBuf,
    location: Location,
    request: Request,
    days: i64,
    since: Option<i64>,
}

struct Snapshot {
    status: Option<Status>,
    capacity: Option<Capacity>,
    rows: Option<Vec<Entry>>,
    storage: Option<Storage>,
    folder: Option<(PathBuf, Option<i64>)>,
    more: bool,
}

impl Snapshot {
    fn load(support: &Path, job: &Job) -> Result<Self> {
        let capacity = platform::capacity(&job.root);
        let mut data = Self {
            status: None,
            capacity,
            rows: None,
            storage: None,
            folder: None,
            more: false,
        };
        let Some(reader) = Reader::open(support)? else {
            return Ok(data);
        };
        let Some(status) = reader.status()?.filter(|status| status.root == job.root) else {
            return Ok(data);
        };
        let changed = job.since != Some(status.revision);
        if changed && job.location.section == Section::Storage {
            data.storage = Some(reader.storage(job.days)?);
        } else if changed {
            let mut request = job.request.clone();
            if job.location.section.browse() {
                request.folder = Some(job.location.folder.unwrap_or(status.root_id));
                data.folder = reader.locate_directory(request.folder.unwrap())?;
                if data.folder.is_none() {
                    request.folder = Some(status.root_id);
                    data.folder = reader.locate_directory(status.root_id)?;
                }
            }
            if job.location.section == Section::Search
                && request.query.trim().is_empty()
                && request.extensions.is_empty()
            {
                data.rows = Some(Vec::new());
            } else {
                let page = reader.page(&request)?;
                data.more = page.more;
                data.rows = Some(page.rows);
            }
        }
        data.status = Some(status);
        Ok(data)
    }
}

type ResultMessage = (u64, Result<Snapshot>);
type PreviewMessage = (PathBuf, Option<shell::Thumbnail>);

#[derive(Clone, Copy, Default)]
struct Controls {
    tabs: HWND,
    title: HWND,
    description: HWND,
    list: HWND,
    query: HWND,
    format: HWND,
    apply: HWND,
    choose: HWND,
    index: HWND,
    up: HWND,
    back: HWND,
    forward: HWND,
    prev: HWND,
    next: HWND,
    reveal: HWND,
    days: HWND,
    ranking: HWND,
    startup: HWND,
    preview: HWND,
    footer: HWND,
    empty: HWND,
    preview_label: HWND,
}

struct App {
    support: PathBuf,
    settings: Option<Settings>,
    location: Location,
    history: Vec<Location>,
    history_index: usize,
    request: Request,
    days: i64,
    ranking: usize,
    rows: Vec<Entry>,
    status: Option<Status>,
    capacity: Option<Capacity>,
    folder: Option<(PathBuf, Option<i64>)>,
    storage: Option<Storage>,
    more: bool,
    last_revision: Option<i64>,
    epoch: u64,
    loading: bool,
    job: Option<Sender<Job>>,
    receive: Option<Receiver<ResultMessage>>,
    preview_job: Option<Sender<PathBuf>>,
    preview_rx: Option<Receiver<PreviewMessage>>,
    preview_path: Option<PathBuf>,
    thumbnail: Option<shell::Thumbnail>,
    preview_panel: bool,
    controls: Controls,
    font: HFONT,
    title_font: HFONT,
    graphic: RECT,
    image_rect: RECT,
}

type WindowState = RefCell<App>;

pub fn run(support: PathBuf) -> Result<()> {
    let existing = unsafe { FindWindowW(text("SpaceTrail.Window").as_ptr(), null()) };
    if !existing.is_null() {
        unsafe {
            ShowWindow(existing, SW_RESTORE);
            SetForegroundWindow(existing);
        }
        return Ok(());
    }
    let Some(_instance) = broker::claim(&support, "window.lock")? else {
        return Ok(());
    };
    let settings = Settings::read(&support)?;
    if settings.is_some() {
        shell::ensure_broker(&support);
    }
    let location = Location {
        section: Section::Files,
        folder: None,
    };
    let app = Box::new(RefCell::new(App {
        support,
        settings,
        location,
        history: vec![location],
        history_index: 0,
        request: Request::default(),
        days: 7,
        ranking: 0,
        rows: Vec::new(),
        status: None,
        capacity: None,
        folder: None,
        storage: None,
        more: false,
        last_revision: None,
        epoch: 0,
        loading: false,
        job: None,
        receive: None,
        preview_job: None,
        preview_rx: None,
        preview_path: None,
        thumbnail: None,
        preview_panel: false,
        controls: Controls::default(),
        font: null_mut(),
        title_font: null_mut(),
        graphic: RECT::default(),
        image_rect: RECT::default(),
    }));
    unsafe {
        let _ = CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32);
        let common = INITCOMMONCONTROLSEX {
            dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES | ICC_TAB_CLASSES | ICC_STANDARD_CLASSES,
        };
        InitCommonControlsEx(&common);
        let class = text("SpaceTrail.Window");
        let registration = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(procedure),
            hInstance: module(),
            hIcon: icon(),
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            hbrBackground: GetSysColorBrush(COLOR_WINDOW),
            lpszClassName: class.as_ptr(),
            ..Default::default()
        };
        let atom = RegisterClassW(&registration);
        win_result((), atom != 0).context("Register the SpaceTrail window")?;
        let state = Box::into_raw(app);
        let hwnd = CreateWindowExW(
            WS_EX_CONTROLPARENT,
            class.as_ptr(),
            text("SpaceTrail").as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1100,
            740,
            null_mut(),
            null_mut(),
            module(),
            state.cast(),
        );
        if hwnd.is_null() {
            drop(Box::from_raw(state));
            return Err(win_result((), false).unwrap_err().into());
        }
        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
        let mut keys = [
            ACCEL {
                fVirt: FVIRTKEY | FCONTROL,
                key: b'F' as u16,
                cmd: ID_FOCUS_SEARCH,
            },
            ACCEL {
                fVirt: FVIRTKEY | FALT,
                key: VK_LEFT,
                cmd: ID_HISTORY_BACK,
            },
            ACCEL {
                fVirt: FVIRTKEY | FALT,
                key: VK_RIGHT,
                cmd: ID_HISTORY_NEXT,
            },
            ACCEL {
                fVirt: FVIRTKEY | FALT,
                key: VK_UP,
                cmd: ID_UP,
            },
        ];
        let accelerator = CreateAcceleratorTableW(keys.as_mut_ptr(), keys.len() as i32);
        let mut message: MSG = zeroed();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            if message.message == WM_KEYDOWN && message.wParam == VK_RETURN as usize {
                let (query, format) = {
                    let app = (*state).borrow();
                    (app.controls.query, app.controls.format)
                };
                let focus = GetFocus();
                if focus == query || focus == format || GetParent(focus) == format {
                    SendMessageW(hwnd, WM_COMMAND, ID_APPLY as usize, 0);
                    continue;
                }
            }
            if TranslateAcceleratorW(hwnd, accelerator, &message) == 0
                && IsDialogMessageW(hwnd, &message) == 0
            {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        DestroyAcceleratorTable(accelerator);
        if IsWindow(hwnd) != 0 {
            DestroyWindow(hwnd);
        }
        drop(Box::from_raw(state));
        CoUninitialize();
    }
    Ok(())
}

unsafe extern "system" fn procedure(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_NCCREATE {
        let create = &*(lp as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
        return 1;
    }
    let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const WindowState;
    if let Some(state) = state.as_ref()
        && let Ok(mut app) = state.try_borrow_mut()
    {
        match msg {
            WM_CREATE => {
                app.initialize(hwnd);
                return 0;
            }
            WM_SIZE => {
                app.layout(hwnd);
                return 0;
            }
            WM_DPICHANGED => {
                let target = &*(lp as *const RECT);
                app.fonts(hwnd);
                SetWindowPos(
                    hwnd,
                    null_mut(),
                    target.left,
                    target.top,
                    target.right - target.left,
                    target.bottom - target.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
                app.layout(hwnd);
                return 0;
            }
            WM_GETMINMAXINFO => {
                let info = &mut *(lp as *mut MINMAXINFO);
                let scale = GetDpiForWindow(hwnd).max(96) as i32;
                info.ptMinTrackSize.x = 790 * scale / 96;
                info.ptMinTrackSize.y = 525 * scale / 96;
                return 0;
            }
            WM_COMMAND => {
                app.command(hwnd, wp as u16, (wp >> 16) as u16);
                return 0;
            }
            WM_NOTIFY => {
                return app.notify(hwnd, lp);
            }
            WM_TIMER => {
                if !app.loading {
                    app.refresh(false);
                }
                return 0;
            }
            DATA_READY => {
                app.publish(hwnd);
                return 0;
            }
            PREVIEW_READY => {
                app.publish_preview(hwnd);
                return 0;
            }
            WM_PAINT => {
                app.draw(hwnd);
                return 0;
            }
            WM_LBUTTONUP if app.location.section == Section::Map => {
                let point = POINT {
                    x: (lp as i16) as i32,
                    y: ((lp >> 16) as i16) as i32,
                };
                let entries = canvas::tiles(app.graphic, &app.rows);
                if let Some((index, _)) = entries
                    .into_iter()
                    .find(|(_, rect)| PtInRect(rect, point) != 0)
                {
                    app.open_item(hwnd, index);
                }
                return 0;
            }
            WM_APPCOMMAND => {
                let action = (lp as u32 >> 16) & 0x0fff;
                if action == APPCOMMAND_BROWSER_BACKWARD || action == APPCOMMAND_BROWSER_FORWARD {
                    app.step_history(hwnd, action == APPCOMMAND_BROWSER_FORWARD);
                    return 1;
                }
            }
            WM_DESTROY => {
                KillTimer(hwnd, 1);
                app.job = None;
                app.preview_job = None;
                PostQuitMessage(0);
                return 0;
            }
            _ => (),
        }
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

impl Drop for App {
    fn drop(&mut self) {
        unsafe {
            if !self.font.is_null() {
                DeleteObject(self.font);
            }
            if !self.title_font.is_null() {
                DeleteObject(self.title_font);
            }
        }
    }
}

unsafe fn control(hwnd: HWND, class: &str, title: &str, id: u16, style: u32, ex: u32) -> HWND {
    CreateWindowExW(
        ex,
        text(class).as_ptr(),
        text(title).as_ptr(),
        WS_CHILD | style,
        0,
        0,
        0,
        0,
        hwnd,
        id as usize as HMENU,
        module(),
        null(),
    )
}

unsafe fn set_text(hwnd: HWND, value: &str) {
    SetWindowTextW(hwnd, text(value).as_ptr());
}

unsafe fn value(hwnd: HWND) -> String {
    let mut chars = vec![0_u16; GetWindowTextLengthW(hwnd).clamp(0, 4096) as usize + 1];
    let count = GetWindowTextW(hwnd, chars.as_mut_ptr(), chars.len() as i32);
    String::from_utf16_lossy(&chars[..count.max(0) as usize])
}

unsafe fn combo(hwnd: HWND, choices: &[&str], selected: usize) {
    for item in choices {
        SendMessageW(hwnd, CB_ADDSTRING, 0, text(item).as_ptr() as LPARAM);
    }
    SendMessageW(hwnd, CB_SETCURSEL, selected, 0);
}

unsafe fn visible(hwnd: HWND, show: bool) {
    ShowWindow(hwnd, if show { SW_SHOW } else { SW_HIDE });
}

fn start_loader(hwnd: HWND, support: PathBuf) -> (Sender<Job>, Receiver<ResultMessage>) {
    let (send, receive) = mpsc::channel::<Job>();
    let (result, output) = mpsc::channel();
    let hwnd = hwnd as usize;
    thread::spawn(move || {
        while let Ok(first) = receive.recv() {
            let job = receive.try_iter().last().unwrap_or(first);
            if result
                .send((job.epoch, Snapshot::load(&support, &job)))
                .is_err()
            {
                break;
            }
            unsafe {
                PostMessageW(hwnd as HWND, DATA_READY, 0, 0);
            }
        }
    });
    (send, output)
}

fn start_previews(hwnd: HWND) -> (Sender<PathBuf>, Receiver<PreviewMessage>) {
    let (send, receive) = mpsc::channel::<PathBuf>();
    let (result, output) = mpsc::channel();
    let hwnd = hwnd as usize;
    thread::spawn(move || unsafe {
        let initialized = CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) >= 0;
        while let Ok(first) = receive.recv() {
            let path = receive.try_iter().last().unwrap_or(first);
            let image = initialized.then(|| shell::thumbnail(&path)).flatten();
            if result.send((path, image)).is_err() {
                break;
            }
            PostMessageW(hwnd as HWND, PREVIEW_READY, 0, 0);
        }
        if initialized {
            CoUninitialize();
        }
    });
    (send, output)
}

impl App {
    unsafe fn initialize(&mut self, hwnd: HWND) {
        let edit = WS_TABSTOP | ES_AUTOHSCROLL as u32;
        let button = WS_TABSTOP | BS_PUSHBUTTON as u32;
        let label = SS_NOPREFIX;
        let style = WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST as u32;
        self.controls = Controls {
            tabs: control(hwnd, "SysTabControl32", "Views", ID_TABS, WS_TABSTOP, 0),
            title: control(hwnd, "Static", "Files", 0, label, 0),
            description: control(hwnd, "Static", "", 0, label, 0),
            list: control(
                hwnd,
                "SysListView32",
                "Indexed items",
                ID_LIST,
                WS_TABSTOP | LVS_REPORT | LVS_OWNERDATA | LVS_SHOWSELALWAYS | LVS_SINGLESEL,
                WS_EX_CLIENTEDGE,
            ),
            query: control(hwnd, "Edit", "", ID_QUERY, edit, WS_EX_CLIENTEDGE),
            format: control(
                hwnd,
                "ComboBox",
                "File format",
                ID_FORMAT,
                WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWN as u32,
                0,
            ),
            apply: control(hwnd, "Button", "Search", ID_APPLY, button, 0),
            choose: control(hwnd, "Button", "Choose Folder…", ID_CHOOSE, button, 0),
            index: control(hwnd, "Button", "Index Windows Drive", ID_INDEX, button, 0),
            up: control(hwnd, "Button", "Up", ID_UP, button, 0),
            back: control(hwnd, "Button", "Back", ID_HISTORY_BACK, button, 0),
            forward: control(hwnd, "Button", "Forward", ID_HISTORY_NEXT, button, 0),
            prev: control(hwnd, "Button", "Previous", ID_PREV, button, 0),
            next: control(hwnd, "Button", "Next", ID_NEXT, button, 0),
            reveal: control(hwnd, "Button", "Show in Explorer", ID_REVEAL, button, 0),
            days: control(hwnd, "ComboBox", "Storage history range", ID_DAYS, style, 0),
            ranking: control(hwnd, "ComboBox", "Storage ranking", ID_RANK, style, 0),
            startup: control(
                hwnd,
                "Button",
                "Start with Windows",
                ID_STARTUP,
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                0,
            ),
            preview: control(hwnd, "Button", "Preview", ID_PREVIEW, button, 0),
            footer: control(hwnd, "Static", "", 0, label, 0),
            empty: control(hwnd, "Static", "Choose a location to index.", 0, label, 0),
            preview_label: control(hwnd, "Static", "", 0, label, 0),
        };
        for (i, section) in Section::ALL.into_iter().enumerate() {
            let mut title = text(section.title());
            let item = TCITEMW {
                mask: TCIF_TEXT,
                pszText: title.as_mut_ptr(),
                ..Default::default()
            };
            SendMessageW(
                self.controls.tabs,
                TCM_INSERTITEMW,
                i,
                &item as *const TCITEMW as LPARAM,
            );
        }
        SendMessageW(
            self.controls.query,
            EM_SETCUEBANNER,
            0,
            text("Search by name").as_ptr() as LPARAM,
        );
        SendMessageW(
            self.controls.list,
            LVM_SETEXTENDEDLISTVIEWSTYLE,
            0,
            (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_LABELTIP) as LPARAM,
        );
        for (i, name) in ["Name", "Folder", "On Disk", "Logical Size", "Modified"]
            .into_iter()
            .enumerate()
        {
            let mut title = text(name);
            let item = LVCOLUMNW {
                mask: LVCF_TEXT | LVCF_WIDTH | LVCF_FMT,
                pszText: title.as_mut_ptr(),
                cx: 140,
                fmt: if i >= 2 { LVCFMT_RIGHT } else { LVCFMT_LEFT },
                ..Default::default()
            };
            SendMessageW(
                self.controls.list,
                LVM_INSERTCOLUMNW,
                i,
                &item as *const LVCOLUMNW as LPARAM,
            );
        }
        combo(
            self.controls.format,
            &[
                "All Formats",
                "PDF",
                "EPUB",
                "Images",
                "Video",
                "Audio",
                "Archives",
            ],
            0,
        );
        combo(
            self.controls.days,
            &["24 Hours", "7 Days", "30 Days", "90 Days"],
            1,
        );
        combo(
            self.controls.ranking,
            &["Recent File Growth", "Largest Files", "Largest Folders"],
            0,
        );
        SendMessageW(
            self.controls.startup,
            BM_SETCHECK,
            usize::from(shell::launch_at_login()),
            0,
        );
        (self.job, self.receive) = {
            let (s, r) = start_loader(hwnd, self.support.clone());
            (Some(s), Some(r))
        };
        (self.preview_job, self.preview_rx) = {
            let (s, r) = start_previews(hwnd);
            (Some(s), Some(r))
        };
        self.fonts(hwnd);
        self.layout(hwnd);
        self.update_text();
        SetTimer(hwnd, 1, 1600, None);
        self.refresh(true);
    }

    unsafe fn fonts(&mut self, hwnd: HWND) {
        let dpi = GetDpiForWindow(hwnd).max(96) as i32;
        let face = text("Segoe UI");
        let make = |size: i32, weight: i32| {
            CreateFontW(
                -size * dpi / 96,
                0,
                0,
                0,
                weight,
                0,
                0,
                0,
                DEFAULT_CHARSET as u32,
                OUT_DEFAULT_PRECIS as u32,
                CLIP_DEFAULT_PRECIS as u32,
                CLEARTYPE_QUALITY as u32,
                DEFAULT_PITCH as u32,
                face.as_ptr(),
            )
        };
        let font = make(14, FW_NORMAL as i32);
        let title = make(27, FW_SEMIBOLD as i32);
        let c = self.controls;
        for child in [
            c.tabs,
            c.description,
            c.list,
            c.query,
            c.format,
            c.apply,
            c.choose,
            c.index,
            c.up,
            c.back,
            c.forward,
            c.prev,
            c.next,
            c.reveal,
            c.days,
            c.ranking,
            c.startup,
            c.preview,
            c.footer,
            c.empty,
            c.preview_label,
        ] {
            SendMessageW(child, WM_SETFONT, font as WPARAM, 1);
        }
        SendMessageW(c.title, WM_SETFONT, title as WPARAM, 1);
        if !self.font.is_null() {
            DeleteObject(self.font);
        }
        if !self.title_font.is_null() {
            DeleteObject(self.title_font);
        }
        self.font = font;
        self.title_font = title;
    }

    unsafe fn layout(&mut self, hwnd: HWND) {
        let mut rect = RECT::default();
        GetClientRect(hwnd, &mut rect);
        let dpi = GetDpiForWindow(hwnd).max(96) as i32;
        let scale = |n: i32| n * dpi / 96;
        let w = rect.right * 96 / dpi;
        let h = rect.bottom * 96 / dpi;
        let place = |child, x, y, width, height| {
            MoveWindow(
                child,
                scale(x),
                scale(y),
                scale(i32::max(1, width)),
                scale(i32::max(1, height)),
                1,
            );
        };
        let c = self.controls;
        let has_scope = self.settings.is_some();
        let section = self.location.section;
        let browse = section.browse();
        let storage = section == Section::Storage;
        let map = section == Section::Map;
        let scope_actions = 300;
        place(c.title, 20, 15, w - scope_actions, 39);
        place(c.description, 21, 56, w - 42, 24);
        place(c.choose, w - 151, 20, 132, 28);
        place(c.index, w - 322, 20, 162, 28);
        visible(c.choose, true);
        visible(c.index, !has_scope);
        place(c.tabs, 20, 87, w - 40, 30);
        visible(c.tabs, has_scope);
        let left = if browse { 232 } else { 20 };
        place(c.back, 20, 127, 69, 29);
        place(c.forward, 93, 127, 70, 29);
        place(c.up, 167, 127, 57, 29);
        for child in [c.back, c.forward, c.up] {
            visible(child, has_scope && browse);
        }
        place(c.query, left, 128, w - left - 282, 28);
        place(c.format, w - 274, 127, 152, 224);
        place(c.apply, w - 113, 127, 93, 29);
        for child in [c.query, c.format, c.apply] {
            visible(child, has_scope && !storage && !map);
        }
        place(c.ranking, 20, 127, 195, 182);
        place(c.days, w - 148, 127, 128, 182);
        visible(c.ranking, has_scope && storage);
        visible(c.days, has_scope && storage);
        place(c.startup, w - 180, h - 33, 164, 24);
        visible(c.startup, has_scope);
        let top = 169;
        let graphic_height = if has_scope && (storage || map) {
            (h / 4).clamp(102, 170)
        } else {
            0
        };
        self.graphic = RECT {
            left: scale(20),
            top: scale(top),
            right: scale(w - 20),
            bottom: scale(top + graphic_height),
        };
        let list_top = top + graphic_height + if graphic_height > 0 { 10 } else { 0 };
        let side = if has_scope && self.preview_panel && !map && !storage {
            202
        } else {
            0
        };
        let list_width = w - 40 - side;
        place(c.list, 20, list_top, list_width, h - list_top - 54);
        visible(c.list, has_scope);
        let cols = [
            list_width * 26 / 100,
            list_width * 35 / 100,
            list_width * 13 / 100,
            list_width * 13 / 100,
            list_width * 13 / 100 - 10,
        ];
        for (i, width) in cols.into_iter().enumerate() {
            SendMessageW(c.list, LVM_SETCOLUMNWIDTH, i, scale(width.max(64)) as isize);
        }
        place(
            c.empty,
            24,
            if has_scope { list_top + 49 } else { 132 },
            w - 56,
            43,
        );
        visible(c.empty, !has_scope || self.rows.is_empty());
        place(c.preview_label, w - 207, list_top + 5, 187, 46);
        visible(c.preview_label, side > 0);
        self.image_rect = RECT {
            left: scale(w - 207),
            top: scale(list_top + 55),
            right: scale(w - 20),
            bottom: scale((list_top + 258).min(h - 60)),
        };
        place(c.reveal, 20, h - 40, 129, 26);
        place(c.preview, 157, h - 40, 81, 26);
        place(c.prev, 246, h - 40, 77, 26);
        place(c.next, 328, h - 40, 72, 26);
        place(c.footer, 410, h - 33, w - 588, 25);
        for child in [c.reveal, c.footer] {
            visible(child, has_scope);
        }
        visible(c.preview, has_scope && !map && !storage);
        visible(c.prev, has_scope && !storage && !map);
        visible(c.next, has_scope && !storage && !map);
        EnableWindow(c.back, i32::from(self.history_index > 0));
        EnableWindow(
            c.forward,
            i32::from(self.history_index + 1 < self.history.len()),
        );
        EnableWindow(
            c.up,
            i32::from(self.folder.as_ref().and_then(|f| f.1).is_some()),
        );
        EnableWindow(c.prev, i32::from(self.request.offset > 0));
        EnableWindow(c.next, i32::from(self.more));
        InvalidateRect(hwnd, null(), 1);
    }

    fn refresh(&mut self, force: bool) {
        if force {
            self.epoch = self.epoch.wrapping_add(1);
            self.last_revision = None;
        }
        let Some(settings) = &self.settings else {
            return;
        };
        if let Some(send) = &self.job {
            let mut request = self.request.clone();
            request.include_folders = self.location.section == Section::Search;
            if self.location.section == Section::Map {
                request = Request::default();
            }
            self.loading = send
                .send(Job {
                    epoch: self.epoch,
                    root: settings.root.clone(),
                    location: self.location,
                    request,
                    days: self.days,
                    since: self.last_revision,
                })
                .is_ok();
        }
    }

    unsafe fn publish(&mut self, hwnd: HWND) {
        let messages = self
            .receive
            .as_ref()
            .map(|rx| rx.try_iter().collect::<Vec<_>>())
            .unwrap_or_default();
        for (epoch, result) in messages {
            if epoch != self.epoch {
                continue;
            }
            self.loading = false;
            match result {
                Ok(result) => {
                    self.last_revision = result.status.as_ref().map(|s| s.revision);
                    self.status = result.status;
                    self.capacity = result.capacity;
                    if let Some(rows) = result.rows {
                        self.folder = result.folder;
                        self.more = result.more;
                        self.set_rows(rows);
                    }
                    if let Some(storage) = result.storage {
                        self.storage = Some(storage);
                        self.apply_ranking();
                    }
                    if self.rows.is_empty() && self.request.offset > 0 {
                        self.request.offset = self.request.offset.saturating_sub(PAGE_SIZE);
                        self.refresh(true);
                    }
                    self.update_text();
                }
                Err(error) => {
                    set_text(self.controls.empty, "Waiting for the saved index…");
                    set_text(self.controls.footer, &format!("{error}"));
                }
            }
        }
        self.layout(hwnd);
    }

    unsafe fn set_rows(&mut self, rows: Vec<Entry>) {
        let selected = self.selected().map(|entry| entry.id);
        if self.rows == rows {
            return;
        }
        self.rows = rows;
        EnableWindow(self.controls.reveal, i32::from(!self.rows.is_empty()));
        SendMessageW(
            self.controls.list,
            LVM_SETITEMCOUNT,
            self.rows.len(),
            LVSICF_NOSCROLL as LPARAM,
        );
        if let Some(index) =
            selected.and_then(|id| self.rows.iter().position(|entry| entry.id == id))
        {
            let item = LVITEMW {
                state: LVIS_SELECTED | LVIS_FOCUSED,
                stateMask: LVIS_SELECTED | LVIS_FOCUSED,
                ..Default::default()
            };
            SendMessageW(
                self.controls.list,
                LVM_SETITEMSTATE,
                index,
                &item as *const LVITEMW as LPARAM,
            );
        }
        InvalidateRect(self.controls.list, null(), 0);
    }

    unsafe fn apply_ranking(&mut self) {
        if let Some(storage) = &self.storage {
            let rows = match self.ranking {
                1 => &storage.largest,
                2 => &storage.folders,
                _ => &storage.recent,
            };
            self.set_rows(rows.clone());
        }
    }

    unsafe fn update_text(&self) {
        let c = self.controls;
        if self.settings.is_none() {
            set_text(c.title, "Choose what to index");
            set_text(
                c.description,
                "Browse files by size and track storage changes on this PC.",
            );
            set_text(
                c.empty,
                "Index the Windows drive or choose a folder to start.",
            );
            return;
        }
        set_text(c.title, self.location.section.title());
        let mut title = text(
            if self.location.section == Section::Storage && self.ranking == 0 {
                "Added On Disk"
            } else {
                "On Disk"
            },
        );
        let column = LVCOLUMNW {
            mask: LVCF_TEXT,
            pszText: title.as_mut_ptr(),
            ..Default::default()
        };
        SendMessageW(
            c.list,
            LVM_SETCOLUMNW,
            2,
            &column as *const LVCOLUMNW as LPARAM,
        );
        let scope = self
            .folder
            .as_ref()
            .filter(|_| self.location.section.browse())
            .map(|(path, _)| display_path(path))
            .or_else(|| self.settings.as_ref().map(|s| display_path(&s.root)))
            .unwrap_or_default();
        let description = if self.location.section == Section::Storage {
            self.capacity
                .map(|space| {
                    format!(
                        "{scope}   ·   {} used   ·   {} free",
                        format_size(space.used()),
                        format_size(space.free)
                    )
                })
                .unwrap_or(scope)
        } else {
            scope
        };
        set_text(c.description, &description);
        let footer = match &self.status {
            None => "Preparing the index…".to_owned(),
            Some(status) if !status.baseline => {
                format!("Indexing… {} items examined", status.processed)
            }
            Some(status) if status.pending => format!("Updating index · {} files", status.indexed),
            Some(status) if status.blocked > 0 => {
                format!("{} files · Limited coverage", status.indexed)
            }
            Some(_) => {
                if self.rows.is_empty() {
                    "0 results".to_owned()
                } else {
                    format!(
                        "{}–{}",
                        self.request.offset + 1,
                        self.request.offset + self.rows.len()
                    )
                }
            }
        };
        set_text(c.footer, &footer);
        let empty = if self.status.is_none() || self.status.as_ref().is_some_and(|s| !s.baseline) {
            if let Ok(error) = fs::read_to_string(self.support.join("broker-error.txt")) {
                format!("Background updates paused. {error}")
            } else {
                "Indexing this location…".to_owned()
            }
        } else if self.location.section == Section::Search
            && self.request.query.is_empty()
            && self.request.extensions.is_empty()
        {
            "Enter a file name or choose a format, then select Search.".to_owned()
        } else if self.location.section == Section::Storage && self.ranking == 0 {
            "No recorded file growth in this period.".to_owned()
        } else {
            "No matching items.".to_owned()
        };
        set_text(c.empty, &empty);
    }

    unsafe fn command(&mut self, hwnd: HWND, id: u16, code: u16) {
        let c = self.controls;
        match id {
            ID_CHOOSE => {
                if let Some(path) = shell::folder_dialog(hwnd) {
                    self.choose(hwnd, path);
                }
            }
            ID_INDEX => {
                self.choose(
                    hwnd,
                    PathBuf::from(format!(
                        "{}\\",
                        env::var("SystemDrive").unwrap_or_else(|_| "C:".into())
                    )),
                );
            }
            ID_STARTUP => {
                let enabled = SendMessageW(c.startup, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
                if let Err(error) = shell::set_launch_at_login(enabled) {
                    show_error(&format!("Could not change starting with Windows. {error}"));
                    SendMessageW(c.startup, BM_SETCHECK, usize::from(!enabled), 0);
                }
            }
            ID_FOCUS_SEARCH => {
                self.navigate(
                    hwnd,
                    Location {
                        section: Section::Search,
                        folder: None,
                    },
                );
                SetFocus(c.query);
            }
            ID_APPLY => {
                self.request.query = value(c.query);
                self.request.extensions = formats(&value(c.format));
                self.request.offset = 0;
                self.refresh(true);
            }
            ID_UP => {
                if let Some(parent) = self.folder.as_ref().and_then(|f| f.1) {
                    self.navigate(
                        hwnd,
                        Location {
                            section: self.location.section,
                            folder: Some(parent),
                        },
                    );
                }
            }
            ID_HISTORY_BACK => self.step_history(hwnd, false),
            ID_HISTORY_NEXT => self.step_history(hwnd, true),
            ID_PREV => {
                self.request.offset = self.request.offset.saturating_sub(PAGE_SIZE);
                self.refresh(true);
            }
            ID_NEXT if self.more => {
                self.request.offset += PAGE_SIZE;
                self.refresh(true);
            }
            ID_REVEAL => {
                if let Some(item) = self.selected().cloned() {
                    self.reveal(&item);
                }
            }
            ID_PREVIEW => {
                self.preview_panel = !self.preview_panel;
                if self.preview_panel {
                    self.request_preview(hwnd);
                } else {
                    self.thumbnail = None;
                    self.preview_path = None;
                }
                set_text(
                    c.preview,
                    if self.preview_panel {
                        "Hide Preview"
                    } else {
                        "Preview"
                    },
                );
                self.layout(hwnd);
            }
            ID_DAYS if code == CBN_SELCHANGE as u16 => {
                self.days = [1, 7, 30, 90]
                    .get(SendMessageW(c.days, CB_GETCURSEL, 0, 0) as usize)
                    .copied()
                    .unwrap_or(7);
                self.refresh(true);
            }
            ID_RANK if code == CBN_SELCHANGE as u16 => {
                self.ranking = SendMessageW(c.ranking, CB_GETCURSEL, 0, 0).max(0) as usize;
                self.apply_ranking();
                self.update_text();
                self.layout(hwnd);
            }
            _ => (),
        }
    }

    unsafe fn choose(&mut self, hwnd: HWND, path: PathBuf) {
        match Settings::choose(&self.support, &path) {
            Ok(settings) => {
                self.settings = Some(settings);
                self.status = None;
                self.storage = None;
                self.set_rows(Vec::new());
                self.location = Location {
                    section: Section::Files,
                    folder: None,
                };
                self.history = vec![self.location];
                self.history_index = 0;
                self.reset_view(hwnd);
                shell::ensure_broker(&self.support);
            }
            Err(error) => show_error(&format!("{error:#}")),
        }
    }

    unsafe fn navigate(&mut self, hwnd: HWND, location: Location) {
        if location != self.location {
            self.location = location;
            self.history.truncate(self.history_index + 1);
            self.history.push(location);
            self.history_index = self.history.len() - 1;
            self.reset_view(hwnd);
        }
    }

    unsafe fn step_history(&mut self, hwnd: HWND, forward: bool) {
        let next = if forward {
            self.history_index + 1
        } else {
            self.history_index.saturating_sub(1)
        };
        if next < self.history.len() && next != self.history_index {
            self.history_index = next;
            self.location = self.history[next];
            self.reset_view(hwnd);
        }
    }

    unsafe fn reset_view(&mut self, hwnd: HWND) {
        let section = self.location.section;
        if let Some(index) = Section::ALL.iter().position(|item| *item == section) {
            SendMessageW(self.controls.tabs, TCM_SETCURSEL, index, 0);
        }
        self.request = Request::default();
        if section == Section::Search {
            self.request.sort = Sort::Name;
            self.request.ascending = true;
        }
        set_text(self.controls.query, "");
        SendMessageW(self.controls.format, CB_SETCURSEL, 0, 0);
        self.folder = None;
        self.thumbnail = None;
        self.preview_path = None;
        self.set_rows(Vec::new());
        if section == Section::Storage {
            self.apply_ranking();
        }
        self.update_text();
        self.layout(hwnd);
        self.refresh(true);
    }

    unsafe fn notify(&mut self, hwnd: HWND, lp: LPARAM) -> LRESULT {
        let header = &*(lp as *const NMHDR);
        if header.idFrom == ID_TABS as usize && header.code == TCN_SELCHANGE {
            let index = SendMessageW(self.controls.tabs, TCM_GETCURSEL, 0, 0);
            if let Some(section) = Section::ALL.get(index as usize) {
                self.navigate(
                    hwnd,
                    Location {
                        section: *section,
                        folder: None,
                    },
                );
            }
        }
        if header.idFrom != ID_LIST as usize {
            return 0;
        }
        match header.code {
            LVN_GETDISPINFOW => {
                let item = &mut (*(lp as *mut NMLVDISPINFOW)).item;
                if item.mask & LVIF_TEXT != 0
                    && let Some(entry) = self.rows.get(item.iItem as usize)
                {
                    let value = match item.iSubItem {
                        1 => entry.path.parent().map(display_path).unwrap_or_default(),
                        2 if self.location.section == Section::Storage && self.ranking == 0 => {
                            format!("+{}", format_size(entry.growth))
                        }
                        2 => format!(
                            "{}{}",
                            if entry.estimated { "≈ " } else { "" },
                            format_size(entry.allocated)
                        ),
                        3 => format_size(entry.logical),
                        4 => shell::date(entry.modified),
                        _ => entry.name.clone(),
                    };
                    if !item.pszText.is_null() && item.cchTextMax > 0 {
                        let utf16 = text(&value);
                        let count = utf16.len().min(item.cchTextMax as usize);
                        std::ptr::copy_nonoverlapping(utf16.as_ptr(), item.pszText, count);
                        *item.pszText.add(count - 1) = 0;
                    }
                }
            }
            LVN_COLUMNCLICK
                if self.location.section != Section::Storage
                    && self.location.section != Section::Map =>
            {
                let clicked = &*(lp as *const NMLISTVIEW);
                let sort = match clicked.iSubItem {
                    0 | 1 => Sort::Name,
                    3 => Sort::Logical,
                    4 => Sort::Modified,
                    _ => Sort::Disk,
                };
                self.request.ascending = if self.request.sort == sort {
                    !self.request.ascending
                } else {
                    sort == Sort::Name
                };
                self.request.sort = sort;
                self.request.offset = 0;
                self.refresh(true);
            }
            NM_DBLCLK => {
                let click = &*(lp as *const NMITEMACTIVATE);
                if click.iItem >= 0 {
                    self.open_item(hwnd, click.iItem as usize);
                }
            }
            LVN_ITEMCHANGED if self.preview_panel => self.request_preview(hwnd),
            LVN_KEYDOWN => {
                let key = &*(lp as *const NMLVKEYDOWN);
                if key.wVKey == VK_RETURN {
                    let index = SendMessageW(
                        self.controls.list,
                        LVM_GETNEXTITEM,
                        usize::MAX,
                        LVNI_SELECTED as LPARAM,
                    );
                    if index >= 0 {
                        self.open_item(hwnd, index as usize);
                    }
                }
            }
            _ => (),
        }
        0
    }

    unsafe fn selected(&self) -> Option<&Entry> {
        let index = SendMessageW(
            self.controls.list,
            LVM_GETNEXTITEM,
            usize::MAX,
            LVNI_SELECTED as LPARAM,
        );
        self.rows.get(index as usize)
    }

    unsafe fn open_item(&mut self, hwnd: HWND, index: usize) {
        if let Some(entry) = self.rows.get(index).cloned() {
            if entry.folder {
                let section = if self.location.section == Section::Map {
                    Section::Map
                } else {
                    Section::Folders
                };
                self.navigate(
                    hwnd,
                    Location {
                        section,
                        folder: Some(entry.id),
                    },
                );
            } else {
                self.reveal(&entry);
            }
        }
    }

    unsafe fn reveal(&mut self, item: &Entry) {
        if let Err(error) = fs::symlink_metadata(&item.path)
            && matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
            )
        {
            self.set_rows(
                self.rows
                    .iter()
                    .filter(|entry| entry.id != item.id)
                    .cloned()
                    .collect(),
            );
            self.refresh(true);
            set_text(
                self.controls.footer,
                "This item is no longer at its indexed location.",
            );
        } else if let Err(error) = shell::reveal(&item.path) {
            show_error(&format!("{error}"));
        }
    }

    unsafe fn request_preview(&mut self, hwnd: HWND) {
        let selection = self
            .selected()
            .filter(|e| !e.folder)
            .map(|e| (e.path.clone(), e.name.clone()));
        let path = selection.as_ref().map(|(path, _)| path);
        if self.preview_path.as_ref() == path {
            return;
        }
        self.thumbnail = None;
        self.preview_path = path.cloned();
        if let Some((path, name)) = selection {
            set_text(
                self.controls.preview_label,
                &format!("{name}\nLoading preview…"),
            );
            if let Some(worker) = &self.preview_job {
                let _ = worker.send(path);
            }
        } else {
            set_text(self.controls.preview_label, "Select a file to preview.");
        }
        InvalidateRect(hwnd, &self.image_rect, 1);
    }

    unsafe fn publish_preview(&mut self, hwnd: HWND) {
        let previews = self
            .preview_rx
            .as_ref()
            .map(|rx| rx.try_iter().collect::<Vec<_>>())
            .unwrap_or_default();
        for (path, image) in previews {
            if self.preview_path.as_ref() != Some(&path) {
                continue;
            }
            self.thumbnail = image;
            let name = path
                .file_name()
                .map(|s| s.to_string_lossy())
                .unwrap_or_default();
            set_text(
                self.controls.preview_label,
                &if self.thumbnail.is_some() {
                    name.into_owned()
                } else {
                    format!("{name}\nPreview unavailable")
                },
            );
        }
        InvalidateRect(hwnd, &self.image_rect, 1);
    }

    unsafe fn draw(&self, hwnd: HWND) {
        let mut state = PAINTSTRUCT::default();
        let dc = BeginPaint(hwnd, &mut state);
        SelectObject(dc, self.font);
        match self.location.section {
            Section::Storage => {
                let history = self
                    .storage
                    .as_ref()
                    .map(|storage| storage.history.as_slice())
                    .unwrap_or_default();
                canvas::history(dc, self.graphic, history);
            }
            Section::Map => canvas::map(dc, self.graphic, &self.rows),
            _ => (),
        }
        if let Some(image) = &self.thumbnail {
            canvas::image(dc, self.image_rect, image);
        }
        EndPaint(hwnd, &state);
    }
}

fn formats(value: &str) -> Vec<String> {
    let values: &[&str] = match value.trim().to_lowercase().as_str() {
        "" | "all formats" => &[],
        "pdf" => &["pdf"],
        "epub" => &["epub"],
        "images" => &[
            "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff", "bmp", "svg",
        ],
        "video" => &["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv"],
        "audio" => &["mp3", "m4a", "flac", "wav", "ogg", "aac", "wma"],
        "archives" => &["zip", "rar", "7z", "gz", "tar", "xz", "bz2"],
        _ => return vec![value.trim().trim_start_matches('.').to_lowercase()],
    };
    values.iter().map(|s| (*s).to_owned()).collect()
}

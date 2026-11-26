use super::{icon, module, shell, text, win_result};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use spacetrail::{
    Settings, broker, display_path,
    index::{Entry, PAGE_SIZE, Reader, Request, Sort, Status, Storage},
    platform::{self, Capacity},
};
use std::{
    borrow::Cow,
    env,
    mem::size_of,
    num::NonZeroIsize,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
    sync::mpsc::{self, Receiver, Sender},
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute},
    System::{
        Com::*,
        SystemServices::{APPCOMMAND_BROWSER_BACKWARD, APPCOMMAND_BROWSER_FORWARD},
    },
    UI::{HiDpi::GetDpiForWindow, WindowsAndMessaging::*},
};
use wry::{
    NewWindowResponse, WebContext, WebView, WebViewBuilder, WebViewBuilderExtWindows,
    http::{Method, Response, StatusCode, Uri, header},
    raw_window_handle::{
        HandleError, HasWindowHandle, RawWindowHandle, Win32WindowHandle, WindowHandle,
    },
};

const WAKE: u32 = WM_APP + 1;
const HISTORY: u32 = WM_APP + 2;
const TIMER: usize = 1;
const APP_PAGE: &str = "spacetrail://local.invalid/index.html";
const APP_HOST: &str = "spacetrail.local.invalid";

fn is_app_page(uri: &Uri) -> bool {
    uri.scheme_str() == Some("https")
        && uri.host() == Some(APP_HOST)
        && uri.port().is_none()
        && uri
            .path_and_query()
            .is_some_and(|path| path.as_str() == "/index.html")
}

fn asset(method: &Method, uri: &Uri) -> Response<Cow<'static, [u8]>> {
    const INDEX: &[u8] = include_bytes!("../../ui/index.html");
    const STYLE: &[u8] = include_bytes!("../../ui/ui.css");
    const SCRIPT: &[u8] = include_bytes!("../../ui/app.js");
    const LOGO: &[u8] = include_bytes!("../../assets/spacetrail.png");
    let (mime, body) = if method == Method::GET && uri.host() == Some("local.invalid") {
        match uri.path() {
            "/index.html" => ("text/html; charset=utf-8", INDEX),
            "/ui.css" => ("text/css; charset=utf-8", STYLE),
            "/app.js" => ("text/javascript; charset=utf-8", SCRIPT),
            "/assets/spacetrail.png" => ("image/png", LOGO),
            _ => ("text/plain", &[][..]),
        }
    } else {
        ("text/plain", &[][..])
    };
    let mut response = Response::new(Cow::Borrowed(body));
    if body.is_empty() {
        *response.status_mut() = StatusCode::NOT_FOUND;
    }
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        mime.parse().expect("valid asset MIME type"),
    );
    response
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Section {
    Storage,
    Files,
    Folders,
    Search,
    Map,
}

#[derive(Clone, Deserialize)]
struct View {
    id: u64,
    section: Section,
    folder: Option<i64>,
    query: String,
    format: String,
    hide_system: bool,
    sort: Sort,
    ascending: bool,
    offset: usize,
    days: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case", tag = "command")]
enum Command {
    Ready,
    View(View),
    Scan { drive: bool, startup: bool },
    Startup { enabled: bool },
    Retry,
    Reveal { id: i64 },
    Preview { id: i64, token: u64 },
}

struct Handle(HWND);

impl HasWindowHandle for Handle {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let hwnd = NonZeroIsize::new(self.0 as isize).ok_or(HandleError::Unavailable)?;
        let raw = RawWindowHandle::Win32(Win32WindowHandle::new(hwnd));
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

struct Com;

impl Com {
    fn initialize() -> Result<Self> {
        let status = unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) };
        anyhow::ensure!(
            status >= 0,
            "Could not initialize Windows desktop services ({status:#x})."
        );
        Ok(Self)
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

#[derive(Clone)]
struct Job {
    root: PathBuf,
    view: View,
    since: Option<i64>,
    starting: bool,
}

#[derive(Serialize)]
struct Folder {
    id: i64,
    path: String,
    parent: Option<i64>,
}

#[derive(Serialize)]
struct Data {
    id: u64,
    items: Vec<Entry>,
    folder: Option<Folder>,
    more: bool,
    storage: Option<Storage>,
}

#[derive(PartialEq, Eq, Serialize)]
struct Activity {
    phase: &'static str,
    indexed: i64,
    processed: i64,
    blocked: i64,
    capacity: Option<Capacity>,
}

struct Snapshot {
    activity: Activity,
    revision: Option<i64>,
    data: Result<Option<Data>>,
}

impl Snapshot {
    fn load(support: &Path, job: &Job) -> Result<Self> {
        let capacity = platform::capacity(&job.root);
        let reader = Reader::open(support)?;
        let status = match &reader {
            Some(reader) => reader.status()?.filter(|status| status.root == job.root),
            None => None,
        };
        let phase = if !job.starting
            && (!broker::running(support) || support.join("broker-error.txt").is_file())
        {
            "paused"
        } else {
            match &status {
                None => "starting",
                Some(status) if !status.baseline => "scanning",
                Some(status) if status.pending => "updating",
                Some(_) => "current",
            }
        };
        let activity = Activity {
            phase,
            capacity,
            indexed: status.as_ref().map_or(0, |status| status.indexed),
            processed: status.as_ref().map_or(0, |status| status.processed),
            blocked: status.as_ref().map_or(0, |status| status.blocked),
        };
        let revision = status.as_ref().map(|status| status.revision);
        let data = match (reader, status) {
            (Some(reader), Some(status)) if revision != job.since => {
                load_data(&reader, &status, &job.view).map(Some)
            }
            (Some(_), Some(_)) => Ok(None),
            _ => Ok(Some(Data {
                id: job.view.id,
                items: Vec::new(),
                folder: None,
                more: false,
                storage: None,
            })),
        };
        Ok(Self {
            activity,
            revision,
            data,
        })
    }
}

fn format_extensions(format: &str) -> Vec<String> {
    let extensions: &[&str] = match format {
        "pdf" => &["pdf"],
        "image" => &[
            "png", "jpg", "jpeg", "webp", "heic", "gif", "svg", "bmp", "tif", "tiff", "avif",
        ],
        "video" => &["mp4", "mov", "mkv", "avi", "wmv", "webm", "m4v", "mpeg"],
        "audio" => &["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "wma"],
        "document" => &[
            "doc", "docx", "pdf", "rtf", "odt", "txt", "md", "xls", "xlsx", "ppt", "pptx", "csv",
        ],
        "ebook" => &["epub", "mobi", "azw", "azw3"],
        "archive" => &["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst"],
        "installer" => &["msi", "exe", "msix", "appx", "msixbundle", "appxbundle"],
        _ => &[],
    };
    extensions
        .iter()
        .map(|extension| (*extension).to_owned())
        .collect()
}

fn load_data(reader: &Reader, status: &Status, view: &View) -> Result<Data> {
    let mut result = Data {
        id: view.id,
        items: Vec::new(),
        folder: None,
        more: false,
        storage: None,
    };
    if view.section == Section::Storage {
        result.storage = Some(reader.storage(view.days)?);
        return Ok(result);
    }
    let mut request = Request {
        query: view.query.trim().chars().take(240).collect(),
        extensions: format_extensions(&view.format),
        hide_system: view.hide_system && matches!(view.section, Section::Files | Section::Search),
        include_folders: view.section == Section::Search,
        sort: view.sort,
        ascending: view.ascending,
        offset: view.offset.min(20_000_000) / PAGE_SIZE * PAGE_SIZE,
        ..Default::default()
    };
    if matches!(view.section, Section::Map | Section::Folders) {
        let mut id = view.folder.unwrap_or(status.root_id);
        let mut directory = reader.locate_directory(id)?;
        if directory.is_none() {
            id = status.root_id;
            directory = reader.locate_directory(id)?;
        }
        request.folder = Some(id);
        result.folder = directory.map(|(path, parent)| Folder {
            id,
            path: display_path(&path),
            parent,
        });
    }
    if view.section != Section::Search
        || !request.query.is_empty()
        || !request.extensions.is_empty()
    {
        let page = reader.page(&request)?;
        result.items = page.rows;
        result.more = page.more;
    }
    Ok(result)
}

struct Worker<Input, Output> {
    send: Sender<Input>,
    receive: Receiver<Output>,
}

fn worker<Input: Send + 'static, Output: Send + 'static>(
    hwnd: HWND,
    init: impl FnOnce() -> Box<dyn FnMut(Input) -> Output> + Send + 'static,
) -> Worker<Input, Output> {
    let (send, jobs) = mpsc::channel();
    let (results, receive) = mpsc::channel();
    let hwnd = hwnd as usize;
    thread::spawn(move || {
        let mut work = init();
        while let Ok(first) = jobs.recv() {
            let job = jobs.try_iter().last().unwrap_or(first);
            if results.send(work(job)).is_err() {
                break;
            }
            unsafe { PostMessageW(hwnd as HWND, WAKE, 0, 0) };
        }
    });
    Worker { send, receive }
}

#[derive(Serialize)]
struct Preview {
    token: u64,
    image: Option<String>,
}

struct App {
    hwnd: HWND,
    webview: WebView,
    support: PathBuf,
    config: Option<Settings>,
    drive: PathBuf,
    commands: Receiver<Command>,
    loader: Worker<Job, (u64, Result<Snapshot>)>,
    previews: Worker<(u64, PathBuf), Preview>,
    view: Option<View>,
    revision: Option<i64>,
    activity: Option<Activity>,
    loading: bool,
    last_storage_refresh: Instant,
    started: Instant,
    paths: Vec<(i64, PathBuf)>,
}

impl App {
    fn emit(&self, event: &str, value: impl Serialize) {
        if let Ok(value) = serde_json::to_string(&value) {
            let _ = self
                .webview
                .evaluate_script(&format!("window.SpaceTrail?.receive('{event}',{value})"));
        }
    }

    fn error(&self, message: &str, retry: bool, reason: &str) {
        self.emit(
            "error",
            serde_json::json!({ "message": message, "retry": retry, "reason": reason }),
        );
    }

    fn settings(&self) {
        self.emit(
            "config",
            serde_json::json!({
                "root": self.config.as_ref().map(|settings| display_path(&settings.root)),
                "startup": shell::launch_at_login(),
                "drive": display_path(&self.drive)
            }),
        );
    }

    fn refresh(&mut self, force: bool) {
        let (Some(config), Some(view)) = (&self.config, &self.view) else {
            return;
        };
        if self.loading && !force {
            return;
        }
        let is_storage = view.section == Section::Storage;
        let check_history =
            is_storage && self.last_storage_refresh.elapsed() > Duration::from_secs(60);
        let job = Job {
            root: config.root.clone(),
            view: view.clone(),
            since: if force || check_history {
                None
            } else {
                self.revision
            },
            starting: self.started.elapsed() < Duration::from_secs(6),
        };
        self.loading = self.loader.send.send(job).is_ok();
    }

    fn drain(&mut self) {
        while let Ok(command) = self.commands.try_recv() {
            self.command(command);
        }
        while let Ok((id, result)) = self.loader.receive.try_recv() {
            if self.view.as_ref().map(|view| view.id) != Some(id) {
                continue;
            }
            self.loading = false;
            match result {
                Ok(snapshot) => self.loaded(snapshot),
                Err(_) => self.error(
                    "The saved index could not be read. SpaceTrail will try again.",
                    true,
                    "query",
                ),
            }
        }
        // The renderer ignores previews for closed dialogs and stale selections.
        while let Ok(preview) = self.previews.receive.try_recv() {
            self.emit("preview", preview);
        }
    }

    fn loaded(&mut self, snapshot: Snapshot) {
        if self.activity.as_ref() != Some(&snapshot.activity) {
            self.emit("status", &snapshot.activity);
            self.activity = Some(snapshot.activity);
        }
        match snapshot.data {
            Ok(Some(data)) => {
                self.revision = snapshot.revision;
                let mut paths: Vec<_> = data
                    .items
                    .iter()
                    .map(|entry| (entry.id, entry.path.clone()))
                    .collect();
                if let Some(folder) = &data.folder {
                    paths.push((folder.id, PathBuf::from(&folder.path)));
                }
                if let Some(storage) = &data.storage {
                    self.last_storage_refresh = Instant::now();
                    paths.extend(
                        storage
                            .recent
                            .iter()
                            .chain(&storage.folders)
                            .chain(&storage.largest)
                            .map(|entry| (entry.id, entry.path.clone())),
                    );
                }
                self.paths = paths;
                self.emit("data", data);
            }
            Ok(None) => {
                // A previous transient read error is cleared by the next successful refresh.
                self.emit("readable", ());
            }
            Err(_) => self.error(
                "This view could not load. SpaceTrail will try again.",
                true,
                "query",
            ),
        }
    }

    fn lookup(&self, id: i64) -> Option<&Path> {
        self.paths
            .iter()
            .find(|(entry, _)| *entry == id)
            .map(|(_, path)| path.as_path())
    }

    fn configure(&mut self, path: PathBuf, startup: bool) -> Result<()> {
        let first = self.config.is_none();
        let settings = Settings::choose(&self.support, &path)?;
        let changed = self.config.as_ref() != Some(&settings);
        self.config = Some(settings);
        if changed {
            self.activity = None;
            self.view = None;
            self.paths.clear();
        }
        self.started = Instant::now();
        self.settings();
        shell::ensure_broker(&self.support).context("Could not start background updates")?;
        if first {
            shell::set_launch_at_login(startup).context("Could not save the sign-in preference")?;
            self.settings();
        }
        Ok(())
    }

    fn command(&mut self, command: Command) {
        let result = match command {
            Command::Ready => {
                self.settings();
                Ok(())
            }
            Command::View(view) => {
                self.view = Some(view);
                self.revision = None;
                self.refresh(true);
                Ok(())
            }
            Command::Scan { drive, startup } => {
                let selected = if drive {
                    Ok(Some(self.drive.clone()))
                } else {
                    shell::folder_dialog(self.hwnd)
                };
                selected.and_then(|path| match path {
                    Some(path) => self.configure(path, startup),
                    None => Ok(()),
                })
            }
            Command::Startup { enabled } => {
                let result = shell::set_launch_at_login(enabled)
                    .context("Could not save the sign-in preference");
                self.settings();
                result
            }
            Command::Retry => {
                self.started = Instant::now();
                shell::ensure_broker(&self.support).context("Could not start background updates")
            }
            Command::Reveal { id } => match self.lookup(id) {
                Some(path) => shell::reveal(path),
                None => Ok(()),
            },
            Command::Preview { id, token } => {
                if let Some(path) = self.lookup(id) {
                    let _ = self.previews.send.send((token, path.to_owned()));
                } else {
                    self.emit("preview", Preview { token, image: None });
                }
                Ok(())
            }
        };
        if let Err(error) = result {
            self.error(&error.to_string(), false, "action");
        }
    }
}

pub fn run(support: PathBuf) -> Result<()> {
    let class = text("SpaceTrail.Window");
    let existing = unsafe { FindWindowW(class.as_ptr(), null()) };
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
    let config = Settings::read(&support)?;
    if config.is_some() {
        let _ = shell::ensure_broker(&support);
    }
    let _com = Com::initialize()?;
    let hwnd = unsafe {
        let registration = WNDCLASSW {
            lpfnWndProc: Some(procedure),
            hInstance: module(),
            hIcon: icon(),
            hCursor: LoadCursorW(null_mut(), IDC_ARROW),
            lpszClassName: class.as_ptr(),
            ..Default::default()
        };
        win_result((), RegisterClassW(&registration) != 0)?;
        let screen = (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        let width = screen.0.clamp(640, 1180);
        let height = (screen.1 - 70).clamp(450, 770);
        let hwnd = CreateWindowExW(
            0,
            class.as_ptr(),
            text("SpaceTrail").as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            width,
            height,
            null_mut(),
            null_mut(),
            module(),
            null_mut(),
        );
        win_result(hwnd, !hwnd.is_null())?
    };
    let (send, commands) = mpsc::channel();
    let callback = hwnd as usize;
    let mut context = WebContext::new(Some(support.join("WebView")));
    let webview = WebViewBuilder::new_with_web_context(&mut context)
        .with_custom_protocol("spacetrail".to_owned(), |_, request| {
            asset(request.method(), request.uri())
        })
        .with_https_scheme(true)
        .with_url(APP_PAGE)
        .with_background_color((19, 22, 32, 255))
        .with_default_context_menus(false)
        .with_browser_accelerator_keys(false)
        .with_navigation_handler(|url| url.parse::<Uri>().is_ok_and(|uri| is_app_page(&uri)))
        .with_new_window_req_handler(|_, _| NewWindowResponse::Deny)
        .with_ipc_handler(move |request| {
            if !is_app_page(request.uri()) || request.body().len() > 8192 {
                return;
            }
            if let Ok(command) = serde_json::from_str(request.body()) {
                let _ = send.send(command);
                unsafe { PostMessageW(callback as HWND, WAKE, 0, 0) };
            }
        })
        .build(&Handle(hwnd));
    let webview = match webview {
        Ok(webview) => webview,
        Err(error) => {
            unsafe { DestroyWindow(hwnd) };
            return Err(error).context("Could not open SpaceTrail. Run setup again to check the Microsoft Edge WebView2 Runtime");
        }
    };
    let index_path = support.clone();
    let loader = worker(hwnd, move || {
        Box::new(move |job: Job| (job.view.id, Snapshot::load(&index_path, &job)))
    });
    let previews = worker(hwnd, || {
        let com = Com::initialize().ok();
        Box::new(move |(token, path): (u64, PathBuf)| Preview {
            token,
            image: com.as_ref().and_then(|_| shell::preview(&path)),
        })
    });
    let drive = env::var("SystemDrive")
        .ok()
        .filter(|name| {
            name.len() == 2 && name.as_bytes()[0].is_ascii_alphabetic() && name.ends_with(':')
        })
        .map_or_else(
            || PathBuf::from(r"C:\"),
            |name| PathBuf::from(format!("{name}\\")),
        );
    let mut app = App {
        hwnd,
        webview,
        support,
        config,
        drive,
        commands,
        loader,
        previews,
        view: None,
        revision: None,
        activity: None,
        loading: false,
        last_storage_refresh: Instant::now(),
        started: Instant::now(),
        paths: Vec::new(),
    };
    unsafe {
        let dark: i32 = 1;
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
            (&dark as *const i32).cast(),
            size_of::<i32>() as u32,
        );
        ShowWindow(hwnd, SW_SHOW);
        SetTimer(hwnd, TIMER, 2800, None);
        let mut message = MSG::default();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            if message.hwnd == hwnd {
                match message.message {
                    WAKE => {
                        app.drain();
                        continue;
                    }
                    WM_TIMER if message.wParam == TIMER => {
                        app.drain();
                        app.refresh(false);
                        continue;
                    }
                    HISTORY => {
                        let delta = if message.wParam == 1 { -1 } else { 1 };
                        let _ = app
                            .webview
                            .evaluate_script(&format!("window.SpaceTrail?.history({delta})"));
                        continue;
                    }
                    _ => {}
                }
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        KillTimer(hwnd, TIMER);
        drop(app);
        if IsWindow(hwnd) != 0 {
            DestroyWindow(hwnd);
        }
    }
    Ok(())
}

unsafe extern "system" fn procedure(hwnd: HWND, message: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match message {
        WM_CLOSE | WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        WM_GETMINMAXINFO => {
            let info = &mut *(lp as *mut MINMAXINFO);
            let dpi = GetDpiForWindow(hwnd).max(96) as i32;
            info.ptMinTrackSize.x = 640 * dpi / 96;
            info.ptMinTrackSize.y = 450 * dpi / 96;
            0
        }
        WM_APPCOMMAND => {
            let command = ((lp >> 16) & 0xfff) as u32;
            match command {
                APPCOMMAND_BROWSER_BACKWARD => {
                    PostMessageW(hwnd, HISTORY, 1, 0);
                    1
                }
                APPCOMMAND_BROWSER_FORWARD => {
                    PostMessageW(hwnd, HISTORY, 2, 0);
                    1
                }
                _ => DefWindowProcW(hwnd, message, wp, lp),
            }
        }
        WM_XBUTTONUP => {
            let button = ((wp >> 16) & 0xffff) as u16;
            match button {
                XBUTTON1 => {
                    PostMessageW(hwnd, HISTORY, 1, 0);
                    1
                }
                XBUTTON2 => {
                    PostMessageW(hwnd, HISTORY, 2, 0);
                    1
                }
                _ => DefWindowProcW(hwnd, message, wp, lp),
            }
        }
        _ => DefWindowProcW(hwnd, message, wp, lp),
    }
}

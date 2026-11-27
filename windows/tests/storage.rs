use spacetrail::{
    Settings, broker,
    index::{Reader, Request},
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

struct Fixture {
    base: PathBuf,
    root: PathBuf,
    support: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base =
            std::env::temp_dir().join(format!("spacetrail-{label}-{}-{nonce}", std::process::id()));
        let root = base.join("root");
        let support = base.join("index");
        fs::create_dir_all(&root).unwrap();
        Settings::choose(&support, &root).unwrap();
        Self {
            base,
            root: root.canonicalize().unwrap(),
            support,
        }
    }

    fn indexed(&self, name: &str) -> bool {
        let request = Request {
            query: name.to_owned(),
            ..Default::default()
        };
        Reader::open(&self.support)
            .ok()
            .flatten()
            .and_then(|reader| reader.page(&request).ok())
            .is_some_and(|page| page.rows.iter().any(|entry| entry.name == name))
    }

    fn ready(&self) -> bool {
        Reader::open(&self.support)
            .ok()
            .flatten()
            .and_then(|reader| reader.status().ok().flatten())
            .is_some_and(|status| status.baseline && !status.pending)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

struct Running(
    Arc<AtomicBool>,
    Option<thread::JoinHandle<anyhow::Result<()>>>,
);

impl Running {
    fn start(support: &Path) -> Self {
        let support = support.to_owned();
        let stop = Arc::new(AtomicBool::new(false));
        let worker = Arc::clone(&stop);
        Self(
            stop,
            Some(thread::spawn(move || broker::run(&support, worker))),
        )
    }

    fn stop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
        if let Some(thread) = self.1.take() {
            thread.join().unwrap().unwrap();
        }
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
        if let Some(thread) = self.1.take() {
            let _ = thread.join();
        }
    }
}

fn wait(note: &str, mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if predicate() {
            return;
        }
        thread::sleep(Duration::from_millis(60));
    }
    panic!("{note}");
}

#[test]
fn compact_index_searches_and_recovers_removed_entries() {
    let fixture = Fixture::new("index");
    let documents = fixture.root.join("Documents");
    fs::create_dir(&documents).unwrap();
    let report = documents.join("Café Report.PDF");
    fs::write(&report, vec![b'p'; 8192]).unwrap();
    fs::write(documents.join("Café Report.pdf.backup"), b"backup").unwrap();
    fs::create_dir(documents.join("folder.pdf")).unwrap();
    broker::scan_once(&fixture.support, &fixture.root).unwrap();

    let reader = Reader::open(&fixture.support).unwrap().unwrap();
    let status = reader.status().unwrap().unwrap();
    assert!(status.baseline);
    assert_eq!(status.indexed, 2);
    let page = reader
        .page(&Request {
            query: "cafe".into(),
            extensions: vec!["pdf".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(page.rows.len(), 1);
    assert_eq!(page.rows[0].logical, 8192);
    assert_eq!(page.rows[0].path, report);
    let allocated = page.rows[0].allocated;
    assert!(allocated > 0);
    let mut filter = Request {
        query: "cafe".into(),
        extensions: vec!["pdf".into()],
        minimum_file_bytes: allocated,
        include_folders: true,
        ..Default::default()
    };
    assert_eq!(reader.page(&filter).unwrap().rows[0].path, report);
    filter.minimum_file_bytes += 1;
    assert!(reader.page(&filter).unwrap().rows.is_empty());
    assert_eq!(reader.storage(7).unwrap().recent.len(), 0);
    drop(reader);

    fs::remove_file(report).unwrap();
    broker::scan_once(&fixture.support, &fixture.root).unwrap();
    assert!(!fixture.indexed("Café Report.PDF"));
    assert!(fixture.indexed("Café Report.pdf.backup"));
    let compound = Reader::open(&fixture.support)
        .unwrap()
        .unwrap()
        .page(&Request {
            extensions: vec!["pdf.backup".into()],
            ..Default::default()
        })
        .unwrap();
    assert_eq!(compound.rows.len(), 1);
    let reader = Reader::open(&fixture.support).unwrap().unwrap();
    assert_eq!(reader.status().unwrap().unwrap().indexed, 1);
}

#[test]
fn automatic_updates_survive_explorer_style_removal_and_broker_restart() {
    let fixture = Fixture::new("watch");
    let documents = fixture.root.join("Documents");
    let trash = fixture.root.join("$Recycle.Bin");
    fs::create_dir(&documents).unwrap();
    fs::create_dir(&trash).unwrap();
    let original = documents.join("camera-original.mov");
    fs::write(&original, vec![42_u8; 4096]).unwrap();

    let mut running = Running::start(&fixture.support);
    wait("first scan did not finish", || {
        fixture.ready() && fixture.indexed("camera-original.mov")
    });
    fs::write(&original, vec![7_u8; 24_576]).unwrap();
    wait("growth did not appear", || {
        Reader::open(&fixture.support)
            .unwrap()
            .unwrap()
            .storage(7)
            .unwrap()
            .recent
            .iter()
            .any(|entry| entry.name == "camera-original.mov" && entry.growth > 0)
    });

    fs::rename(&original, trash.join("discarded.mov")).unwrap();
    wait(
        "move to the system Trash did not remove the original row",
        || !fixture.indexed("camera-original.mov"),
    );
    assert!(!fixture.indexed("discarded.mov"));

    let offline = documents.join("gone-while-offline.txt");
    fs::write(&offline, b"old").unwrap();
    wait("new file did not appear", || {
        fixture.indexed("gone-while-offline.txt")
    });
    running.stop();
    fs::remove_file(&offline).unwrap();
    let mut restarted = Running::start(&fixture.support);
    wait("offline removal was not reconciled", || {
        !fixture.indexed("gone-while-offline.txt")
    });
    restarted.stop();

    let reader = Reader::open(&fixture.support).unwrap().unwrap();
    assert_eq!(reader.status().unwrap().unwrap().indexed, 0);
    assert!(reader.storage(30).unwrap().recent.is_empty());
}

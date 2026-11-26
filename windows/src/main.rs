#![cfg_attr(windows, windows_subsystem = "windows")]

use anyhow::{Result, bail};
use spacetrail::{
    broker,
    index::{Reader, Request},
};
use std::{env, path::PathBuf};

#[cfg(windows)]
mod desktop;

fn main() {
    if let Err(error) = run() {
        #[cfg(windows)]
        desktop::show_error(&format!("{error:#}"));
        #[cfg(not(windows))]
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let mut args = env::args_os().skip(1);
    match args.next().as_deref().and_then(|arg| arg.to_str()) {
        Some("--scan-once") => {
            let (Some(root), Some(support)) = (args.next(), args.next()) else {
                bail!("Usage: spacetrail --scan-once <folder> <index-directory>");
            };
            broker::scan_once(&PathBuf::from(support), &PathBuf::from(root))
        }
        Some("--list") => {
            let Some(support) = args.next() else {
                bail!("Usage: spacetrail --list <index-directory>");
            };
            if let Some(reader) = Reader::open(&PathBuf::from(support))? {
                for entry in reader.page(&Request::default())?.rows {
                    println!("{}\t{}", entry.allocated, entry.path.display());
                }
            }
            Ok(())
        }
        #[cfg(windows)]
        Some("--broker") => desktop::start_broker(),
        #[cfg(windows)]
        None => desktop::start_window(),
        _ => {
            bail!("Use the Windows desktop build, or --scan-once and --list for local diagnostics.")
        }
    }
}

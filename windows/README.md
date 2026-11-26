# SpaceTrail for Windows

SpaceTrail keeps a local index of your local drives, so you can explore its files and storage as soon as you open the app. The Windows edition uses a Rust broker, SQLite, and the Microsoft Edge WebView2 Runtime for the desktop window.

## Install the preview

Download **SpaceTrail-Setup-x64.exe** for most Intel and AMD PCs or **SpaceTrail-Setup-arm64.exe** for Windows on Arm. [Windows preview release](https://github.com/saropuglisi/SpaceTrail/releases/tag/windows-v0.3.0)

Run Setup on Windows 11 for a new installation or to update an existing copy. Setup closes running copies, replaces the application, and keeps your saved index and sign-in preference. SpaceTrail is available in the Start menu.

SpaceTrail starts scanning accessible fixed drives with drive letters automatically. **First Scan** shows each drive and its progress. A saved drive index resumes after the update, and additional drives start their own scans. Files and Search cover all indexed drives by default, and the Drive selector narrows the view. You can still limit scanning to a folder in **Settings**.

The broker continues in the notification area after you close the window. Manage background startup in **Settings**.

- **Storage** shows free space and usage history by drive, recent file growth, and the largest files and folders.
- **Files and Search** offer sorting, name and file type filters, Windows thumbnails, and a **Show system files** option.
- **Folders and Map** show the space used by subfolders and let you open locations in Explorer.

**On disk** shows allocated bytes. A leading **≈** marks an estimate, shared allocation, or incomplete folder coverage. Use **Show in Explorer** to manage files. SpaceTrail runs under the current user account and skips directory junctions, the Recycle Bin, and its own index.

Uninstall SpaceTrail from **Settings → Apps → Installed apps**. Scan data stays in `%LOCALAPPDATA%\SpaceTrail` for future installations. Remove that folder after uninstalling if you also want to clear the saved index.

## Build

On Windows, install Rust 1.89 or newer and the Visual Studio C++ Build Tools and Windows SDK for your target architecture. From the repository root, run:

```powershell
.\Scripts\build-windows.ps1
```

Add `-Architecture arm64` to select Windows on Arm explicitly. Use `rustup target add aarch64-pc-windows-msvc` or `rustup target add x86_64-pc-windows-msvc` if that target is missing.

On macOS or Linux, put the LLVM-MinGW UCRT toolchain on your path or set `LLVM_MINGW_BIN` to its `bin` directory. Add the Rust targets and build:

```sh
rustup target add x86_64-pc-windows-gnullvm aarch64-pc-windows-gnullvm
./Scripts/build-windows.sh
```

Native Windows builds include SQLite and the WebView2 loader in the executable. Cross-builds place the executable and its architecture-specific WebView2 loader DLL together in `dist/windows/SpaceTrail-x64` or `dist/windows/SpaceTrail-arm64`. Keep the two files together.

With NSIS installed on Windows, run `.\Scripts\package-windows.ps1` to create the setup executable. Setup includes Microsoft's WebView2 bootstrapper for systems that need the runtime. The [Windows build workflow](../.github/workflows/windows.yml) builds and checks each installer on its target architecture.

## Verify

Run the index tests on the host:

```sh
cargo test --locked --manifest-path windows/Cargo.toml
```

The tests cover name and format filtering, growth, moves to the Recycle Bin, removals during broker downtime, and restart recovery. On Windows, the watcher uses the system directory-change APIs through `notify`. The broker reads individual changed paths, updates the compact index in SQLite transactions, and reconciles folders in batches after a restart or missed events. The desktop window reads saved results independently.

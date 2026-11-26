# SpaceTrail for Windows

SpaceTrail keeps a local index of a drive or folder, so you can explore its files and storage without starting a new scan each time. The Windows edition is a native desktop app written in Rust with SQLite.

## Run the preview

Download the portable executable from the [Windows preview release](https://github.com/saropuglisi/SpaceTrail/releases/tag/windows-v0.1.0).

Use `SpaceTrail-x64.exe` on an Intel or AMD PC, or `SpaceTrail-arm64.exe` on Windows on Arm. Keep the portable executable in a stable folder if you enable **Start with Windows**.

Open SpaceTrail on Windows 11 and choose **Index Windows Drive** or **Choose Folder…**. The first scan checkpoints by directory and publishes partial results in batches. Once you close the window, the broker continues from the notification area. Use its icon to reopen SpaceTrail or quit background updates.

- **Files and Search** offer sorting, name and extension filters, and previews from installed Windows thumbnail providers.
- **Folders and Map** show the space used by subfolders and let you open locations in Explorer.
- **Storage** shows free space, historical samples, largest files and folders, and recent file growth.

**On Disk** shows allocated bytes. A leading **≈** marks an estimate, shared allocation, or incomplete folder coverage. Use **Show in Explorer** to manage files. The preview runs under the current user account and skips directory junctions, the Recycle Bin, and its own index. SQLite and settings are stored in `%LOCALAPPDATA%\SpaceTrail`.

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

The executable includes SQLite and Windows resources. Builds are written to `dist/windows`.

## Verify

Run the index tests on the host:

```sh
cargo test --locked --manifest-path windows/Cargo.toml
```

The tests cover name and format filtering, growth, moves to the Recycle Bin, removals during broker downtime, and restart recovery. On Windows, the watcher uses the system directory-change APIs through `notify`. The broker reads individual changed paths, updates the compact index in SQLite transactions, and reconciles folders in batches after a restart or missed events. The desktop window reads saved results independently.

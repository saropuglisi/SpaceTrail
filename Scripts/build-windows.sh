#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${LLVM_MINGW_BIN:-}" ]]; then
    export PATH="$LLVM_MINGW_BIN:$PATH"
fi
if command -v rustup >/dev/null; then
    export PATH="$(dirname "$(rustup which rustc)"):$PATH"
fi

if [[ "$#" == 0 ]]; then
    set -- x64 arm64
fi
for arch in "$@"; do
    case "$arch" in
        x64)
            target=x86_64-pc-windows-gnullvm
            cc=x86_64-w64-mingw32-clang
            export CC_x86_64_pc_windows_gnullvm="$cc"
            export AR_x86_64_pc_windows_gnullvm=llvm-ar
            export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER="$cc"
            ;;
        arm64)
            target=aarch64-pc-windows-gnullvm
            cc=aarch64-w64-mingw32-clang
            export CC_aarch64_pc_windows_gnullvm="$cc"
            export AR_aarch64_pc_windows_gnullvm=llvm-ar
            export CARGO_TARGET_AARCH64_PC_WINDOWS_GNULLVM_LINKER="$cc"
            ;;
        *) printf 'Unsupported Windows architecture: %s\n' "$arch" >&2; exit 2 ;;
    esac
    command -v "$cc" >/dev/null || { printf 'Install LLVM-MinGW or set LLVM_MINGW_BIN.\n' >&2; exit 1; }
    # Statically link the toolchain's unwinder.
    cargo rustc --bin spacetrail --release --locked --manifest-path windows/Cargo.toml \
        --target-dir windows/target --target "$target" -- -Ctarget-feature=+crt-static
    release="windows/target/$target/release"
    shopt -s nullglob
    loaders=("$release"/build/webview2-com-sys-*/out/"$arch"/WebView2Loader.dll)
    (("${#loaders[@]}" > 0)) || { printf 'Could not find the WebView2 loader for %s.\n' "$arch" >&2; exit 1; }
    loader="${loaders[0]}"
    for candidate in "${loaders[@]}"; do
        if [[ "$candidate" -nt "$loader" ]]; then
            loader="$candidate"
        fi
    done
    destination="dist/windows/SpaceTrail-$arch"
    mkdir -p "$destination"
    install -m 755 "$release/spacetrail.exe" "$destination/SpaceTrail.exe"
    install -m 644 "$loader" "$destination/WebView2Loader.dll"
    printf '%s/%s\n' "$PWD" "$destination"
done

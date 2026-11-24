#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_flags=("$@")
clang_overlay=""
developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == /Library/Developer/CommandLineTools ]]; then
    # Older CLT installs can retain incompatible SwiftPM interfaces and Clang module maps.
    # Isolate both in the build directory, leaving the selected SDK and toolchain untouched.
    workaround="$PWD/.build/toolchain-overlay"
    manifest="$developer_dir/usr/lib/swift/pm/ManifestAPI"
    if [[ -f "$manifest/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface" ]] &&
       ! /usr/bin/grep -q swiftLanguageModes "$manifest/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"; then
        mkdir -p "$workaround/ManifestAPI"
        /usr/bin/rsync -a --exclude='*.private.swiftinterface' "$manifest/" "$workaround/ManifestAPI/"
        export SWIFTPM_CUSTOM_LIBS_DIR="$workaround"
    fi
    map_dir="$developer_dir/usr/include/swift"
    if [[ -f "$map_dir/module.modulemap" && -f "$map_dir/bridging.modulemap" ]] &&
       /usr/bin/grep -q 'module SwiftBridging' "$map_dir/module.modulemap" &&
       /usr/bin/grep -q 'module SwiftBridging' "$map_dir/bridging.modulemap"; then
        mkdir -p "$workaround"
        /usr/bin/python3 - "$workaround" "$map_dir/module.modulemap" <<'PY'
from pathlib import Path
import json
import sys

workaround = Path(sys.argv[1])
empty = workaround / "empty.modulemap"
empty.write_text("")
(workaround / "clang-overlay.json").write_text(json.dumps({
    "version": 0,
    "use-external-names": False,
    "roots": [{"type": "file", "name": sys.argv[2], "external-contents": str(empty)}]
}))
PY
        clang_overlay="$workaround/clang-overlay.json"
        build_flags+=(-Xswiftc -vfsoverlay -Xswiftc "$clang_overlay")
    fi
fi

swift build -c release ${build_flags[@]+"${build_flags[@]}"}
binary_dir=$(swift build -c release ${build_flags[@]+"${build_flags[@]}"} --show-bin-path)

mkdir -p "$PWD/dist"
staging=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/SpaceTrail.app"
broker="$app/Contents/Helpers/SpaceTrail Broker.app"

mkdir -p "$app/Contents/"{MacOS,Resources,Library/LaunchAgents} "$broker/Contents/"{MacOS,Resources}
install -m 755 "$binary_dir/SpaceTrail" "$app/Contents/MacOS/SpaceTrail"
install -m 755 "$binary_dir/SpaceTrailBroker" "$broker/Contents/MacOS/SpaceTrailBroker"
install -m 644 Packaging/App-Info.plist "$app/Contents/Info.plist"
install -m 644 Packaging/Broker-Info.plist "$broker/Contents/Info.plist"
install -m 644 Packaging/io.spacetrail.broker.plist "$app/Contents/Library/LaunchAgents/"

iconset="$staging/SpaceTrail.iconset"
mkdir -p "$iconset"
normalized_icon="$staging/SpaceTrail-icon.png"
if [[ -n "$clang_overlay" ]]; then
    swift -vfsoverlay "$clang_overlay" Packaging/NormalizeIcon.swift Packaging/SpaceTrail.png "$normalized_icon"
else
    swift Packaging/NormalizeIcon.swift Packaging/SpaceTrail.png "$normalized_icon"
fi
for side in 16 32 128 256 512; do
    /usr/bin/sips -z "$side" "$side" "$normalized_icon" --out "$iconset/icon_${side}x${side}.png" >/dev/null
    retina=$((side * 2))
    /usr/bin/sips -z "$retina" "$retina" "$normalized_icon" --out "$iconset/icon_${side}x${side}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/SpaceTrail.icns"
install -m 644 "$app/Contents/Resources/SpaceTrail.icns" "$broker/Contents/Resources/SpaceTrail.icns"

identity=${SPACETRAIL_SIGN_IDENTITY:--}
codesign --force --sign "$identity" "$broker"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

destination="$PWD/dist/SpaceTrail.app"
if [[ -d "$destination" ]]; then
    mv "$destination" "$staging/previous.app"
fi
if ! mv "$app" "$destination"; then
    if [[ -d "$staging/previous.app" ]]; then mv "$staging/previous.app" "$destination"; fi
    exit 1
fi
printf '\n%s\n' "$destination"

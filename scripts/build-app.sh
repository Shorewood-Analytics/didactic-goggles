#!/bin/sh
set -eu

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'Building Disk Watch requires macOS with Xcode command-line tools.' >&2
    exit 1
fi

swift build -c release --product DiskWatch
binary_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/dist/DiskWatch.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/DiskWatch" "$app_dir/Contents/MacOS/DiskWatch"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign "${DISK_WATCH_SIGNING_IDENTITY:--}" \
    --options runtime --entitlements Resources/DiskWatch.entitlements "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"

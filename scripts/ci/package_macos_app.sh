#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "usage: $0 <app-name> <executable-path> <bundle-path> <framework-dir> [resource ...]" >&2
    exit 1
fi

app_name="$1"
executable_path="$2"
bundle_path="$3"
framework_dir="$4"
shift 4

if [[ ! -f "$executable_path" ]]; then
    echo "missing executable: $executable_path" >&2
    exit 1
fi

if [[ ! -d "$framework_dir" ]]; then
    echo "missing framework source directory: $framework_dir" >&2
    exit 1
fi

contents_dir="$bundle_path/Contents"
macos_dir="$contents_dir/MacOS"
frameworks_dir="$contents_dir/Frameworks"
resources_dir="$contents_dir/Resources"
plist_path="$contents_dir/Info.plist"
bundle_id="com.nova3d.${app_name,,}"

rm -rf "$bundle_path"
mkdir -p "$macos_dir" "$frameworks_dir" "$resources_dir"

cp "$executable_path" "$macos_dir/$app_name"
chmod +x "$macos_dir/$app_name"

find "$framework_dir" -maxdepth 1 -type f -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
    cp "$dylib" "$frameworks_dir/"
done

for resource_path in "$@"; do
    if [[ ! -e "$resource_path" ]]; then
        echo "missing resource path: $resource_path" >&2
        exit 1
    fi

    base_name="$(basename "$resource_path")"
    if [[ -d "$resource_path" ]]; then
        cp -R "$resource_path" "$resources_dir/$base_name"
    else
        cp "$resource_path" "$resources_dir/$base_name"
    fi
done

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$app_name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

install_name_tool -add_rpath "@executable_path/../Frameworks" "$macos_dir/$app_name" 2>/dev/null || true

find "$frameworks_dir" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
done
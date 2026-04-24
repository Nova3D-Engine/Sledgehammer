#!/usr/bin/env bash

set -euo pipefail

export COPYFILE_DISABLE=1

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
bundle_name_lower="$(printf '%s' "$app_name" | tr '[:upper:]' '[:lower:]')"
bundle_id="com.nova3d.$bundle_name_lower"

rm -rf "$bundle_path"
mkdir -p "$macos_dir" "$frameworks_dir" "$resources_dir"

cp -X "$executable_path" "$macos_dir/$app_name"
chmod +x "$macos_dir/$app_name"

find "$framework_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
    cp -RX "$dylib" "$frameworks_dir/"
done

for vulkan_candidate in \
    "$framework_dir/libvulkan.1.dylib" \
    "/opt/homebrew/lib/libvulkan.1.dylib" \
    "/usr/local/lib/libvulkan.1.dylib" \
    "/opt/homebrew/opt/vulkan-loader/lib/libvulkan.1.dylib" \
    "/usr/local/opt/vulkan-loader/lib/libvulkan.1.dylib"
do
    if [[ -e "$vulkan_candidate" && ! -e "$frameworks_dir/libvulkan.1.dylib" ]]; then
        cp -L "$vulkan_candidate" "$frameworks_dir/libvulkan.1.dylib"
        break
    fi
done

for resource_path in "$@"; do
    if [[ ! -e "$resource_path" ]]; then
        echo "missing resource path: $resource_path" >&2
        exit 1
    fi

    base_name="$(basename "$resource_path")"
    if [[ -d "$resource_path" ]]; then
        cp -RX "$resource_path" "$resources_dir/$base_name"
    else
        cp -X "$resource_path" "$resources_dir/$base_name"
    fi
done

find "$resources_dir" -name '.DS_Store' -delete 2>/dev/null || true

framework_entries=()
while IFS= read -r framework_entry; do
    framework_entries+=("$framework_entry")
done < <(find "$frameworks_dir" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' -print | sort)

rewrite_macho_links() {
    local target_path="$1"
    local framework_path
    local framework_name
    local framework_realpath
    local current_id
    local target_deps

    for framework_path in "${framework_entries[@]}"; do
        framework_name="$(basename "$framework_path")"
        framework_realpath="$(cd "$(dirname "$framework_path")" && pwd -P)/$(basename "$(readlink "$framework_path" 2>/dev/null || printf '%s' "$framework_name")")"

        if [[ -f "$framework_path" ]]; then
            install_name_tool -id "@rpath/$framework_name" "$framework_path" 2>/dev/null || true
        fi

        target_deps="$(otool -L "$target_path" | tail -n +2 | awk '{print $1}')"
        while IFS= read -r current_id; do
            [[ -n "$current_id" ]] || continue
            case "$current_id" in
                "@rpath/$framework_name"|"@loader_path/$framework_name"|"@executable_path/../Frameworks/$framework_name")
                    install_name_tool -change "$current_id" "@rpath/$framework_name" "$target_path" 2>/dev/null || true
                    ;;
                "$framework_path"|"$framework_realpath")
                    install_name_tool -change "$current_id" "@rpath/$framework_name" "$target_path" 2>/dev/null || true
                    ;;
                */$framework_name)
                    install_name_tool -change "$current_id" "@rpath/$framework_name" "$target_path" 2>/dev/null || true
                    ;;
            esac
        done <<< "$target_deps"
    done
}

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
rewrite_macho_links "$macos_dir/$app_name"

find "$frameworks_dir" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
    rewrite_macho_links "$dylib"
done
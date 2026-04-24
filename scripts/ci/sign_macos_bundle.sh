#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <bundle-path>" >&2
    exit 1
fi

bundle_path="$1"
identity="${MACOS_SIGNING_IDENTITY:--}"
timestamp_args=(--timestamp=none)

if [[ ! -d "$bundle_path" ]]; then
    echo "missing bundle: $bundle_path" >&2
    exit 1
fi

if [[ "$identity" != "-" ]]; then
    timestamp_args=(--timestamp)
fi

xattr -cr "$bundle_path" 2>/dev/null || true
for attr_name in com.apple.provenance com.apple.FinderInfo 'com.apple.fileprovider.fpfs#P'; do
    find "$bundle_path" -exec xattr -d "$attr_name" {} \; 2>/dev/null || true
done

find "$bundle_path/Contents/Frameworks" -type f -name '*.dylib' -print0 2>/dev/null | while IFS= read -r -d '' dylib; do
    codesign --force --sign "$identity" "${timestamp_args[@]}" "$dylib"
done

codesign --force --deep --sign "$identity" "${timestamp_args[@]}" "$bundle_path"
codesign --verify --deep --strict "$bundle_path"
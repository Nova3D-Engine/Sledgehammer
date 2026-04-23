#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <bundle-path>" >&2
    exit 1
fi

bundle_path="$1"
identity="${MACOS_SIGNING_IDENTITY:--}"

if [[ ! -d "$bundle_path" ]]; then
    echo "missing bundle: $bundle_path" >&2
    exit 1
fi

find "$bundle_path/Contents/Frameworks" -type f -name '*.dylib' -print0 2>/dev/null | while IFS= read -r -d '' dylib; do
    codesign --force --sign "$identity" --timestamp=none "$dylib"
done

codesign --force --deep --sign "$identity" --timestamp=none "$bundle_path"
codesign --verify --deep --strict "$bundle_path"
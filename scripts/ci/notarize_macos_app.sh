#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <bundle-path> <zip-path>" >&2
    exit 1
fi

bundle_path="$1"
zip_path="$2"

apple_id="${APPLE_NOTARY_APPLE_ID:-}"
team_id="${APPLE_NOTARY_TEAM_ID:-}"
app_password="${APPLE_NOTARY_APP_PASSWORD:-}"

if [[ ! -d "$bundle_path" ]]; then
    echo "missing bundle: $bundle_path" >&2
    exit 1
fi

if [[ ! -f "$zip_path" ]]; then
    echo "missing zip: $zip_path" >&2
    exit 1
fi

if [[ -z "$apple_id" || -z "$team_id" || -z "$app_password" ]]; then
    echo "missing Apple notarization credentials" >&2
    exit 1
fi

xcrun notarytool submit "$zip_path" \
    --apple-id "$apple_id" \
    --team-id "$team_id" \
    --password "$app_password" \
    --wait

xcrun stapler staple "$bundle_path"
xcrun stapler validate "$bundle_path"

rm -f "$zip_path"
ditto -c -k --keepParent "$bundle_path" "$zip_path"
#!/usr/bin/env bash
# Builds dbg-CrashSentry.zip in the layout the Brotato ModLoader expects:
#   <zip root>/mods-unpacked/<namespace>-<name>/{manifest.json, mod_main.gd, ...}
set -euo pipefail

cd "$(dirname "$0")"
MOD_ID="dbg-CrashSentry"

if [ ! -f "$MOD_ID/manifest.json" ] || [ ! -f "$MOD_ID/mod_main.gd" ]; then
	echo "run this from the folder that contains $MOD_ID/" >&2
	exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/mods-unpacked"
cp -r "$MOD_ID" "$STAGE/mods-unpacked/"
find "$STAGE" -name '*.tmp' -delete

( cd "$STAGE" && zip -q -r -X "$MOD_ID.zip" mods-unpacked )
mv "$STAGE/$MOD_ID.zip" "./$MOD_ID.zip"

echo "built: $PWD/$MOD_ID.zip"
unzip -l "$MOD_ID.zip" | tail -n +2 | head -12

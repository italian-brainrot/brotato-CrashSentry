#!/usr/bin/env bash
# Removes the local dev copy of the mod from every place install.sh can write to.
set -euo pipefail
STEAM_ROOT=""
for root in "$HOME" /home/qq /var/home/qq; do
	if [ -d "$root/.local/share/Steam/steamapps" ]; then STEAM_ROOT="$root/.local/share/Steam"; break; fi
done
MOD_ID="dbg-CrashSentry"
removed=0
for f in "$STEAM_ROOT/steamapps/common/Brotato/mods/$MOD_ID.zip" "$STEAM_ROOT"/steamapps/workshop/content/1942280/*/"$MOD_ID.zip"; do
	if [ -f "$f" ]; then rm -f "$f"; echo "removed: $f"; removed=1; fi
done
[ "$removed" = 1 ] || echo "nothing to remove (no copy of $MOD_ID.zip found)"
echo
echo "the flight recorder data stays in: $STEAM_ROOT/../Brotato/logs/sentry (user://logs/sentry)"

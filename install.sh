#!/usr/bin/env bash
# Build the mod and put it where Brotato's ModLoader will actually find it.
#
#   ./install.sh                      build only, then print the options
#   ./install.sh items                list the workshop item folders you can use
#   ./install.sh workshop <item id>   copy the zip into that subscribed workshop item folder
#   ./install.sh dir <path>           copy the zip into an arbitrary folder (e.g. <game>/mods)
#
# Why "workshop": the retail Steam build ships with steam_workshop_enabled = true,
# so the plain <game>/mods folder is ignored and --mods-path is not honoured.
# The mod loader, however, mounts *every* .zip it finds inside *every subscribed*
# workshop item folder - so dropping your build next to an item you already
# subscribe to is the fastest way to test locally without publishing.
set -euo pipefail

cd "$(dirname "$0")"
MOD_ID="dbg-CrashSentry"
# find the Steam folder: inside a container $HOME is not the home Steam lives in
STEAM_ROOT=""
for root in "$HOME" /home/qq /var/home/qq; do
	if [ -d "$root/.local/share/Steam/steamapps" ]; then
		STEAM_ROOT="$root/.local/share/Steam"
		break
	fi
done
WORKSHOP="$STEAM_ROOT/steamapps/workshop/content/1942280"
GAME_DIR="$STEAM_ROOT/steamapps/common/Brotato"

./build.sh

mode="${1:-}"
case "$mode" in
	items)
		echo "subscribed workshop item folders:"
		for d in "$WORKSHOP"/*/; do
			[ -d "$d" ] || continue
			echo "  $(basename "$d")  <- $(ls "$d" | tr '\n' ' ')"
		done
		echo "then run: ./install.sh workshop <one of those ids>"
		exit 0
		;;
	workshop)
		item="${2:?usage: ./install.sh workshop <workshop item id>}"
		target="$WORKSHOP/$item"
		[ -d "$target" ] || { echo "no such workshop item folder: $target" >&2; exit 1; }
		cp -f "$MOD_ID.zip" "$target/"
		echo "installed: $target/$MOD_ID.zip"
		;;
	dir)
		target="${2:?usage: ./install.sh dir <path>}"
		mkdir -p "$target"
		cp -f "$MOD_ID.zip" "$target/"
		echo "installed: $target/$MOD_ID.zip"
		;;
	"")
		echo
		echo "Not installed anywhere yet. Options:"
		echo "  ./install.sh items"
		echo "  ./install.sh workshop <item id>        # quickest local test"
		echo "  ./install.sh dir \"$GAME_DIR/mods\"  # only works with a no-workshop options profile"
		echo "  upload it to the Workshop with GodotWorkshopUtility (the proper way, shareable)"
		exit 0
		;;
	*)
		echo "unknown mode: $mode" >&2
		exit 1
		;;
esac

echo "restart Brotato completely (quit to desktop, not just back to the main menu) to pick it up."

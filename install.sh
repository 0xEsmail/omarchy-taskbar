#!/bin/bash
# Installs or updates Taskbar from this folder. Safe to re-run after edits.
#
#   ./install.sh                first install, or update an existing one
#   ./install.sh --keep-layout  first install without the Windows layout
#
#   First install: copies the plugin into ~/.config/omarchy/plugins, adds it
#                  to the bar and pins the apps your dock pins. Taskbar then
#                  sets up the Windows layout itself (bottom bar, centered,
#                  clock in the corner), saving your bar first so
#                  uninstall.sh can put it back.
#   Update:        copies the new files and restarts the shell. The shell
#                  announces a hot reload for a changed bar widget but keeps
#                  running the old code, so a restart is what loads it.
set -euo pipefail

KEEP_LAYOUT=0
case "${1:-}" in
  --keep-layout) KEEP_LAYOUT=1 ;;
  "") ;;
  *) echo "usage: $0 [--keep-layout]" >&2; exit 2 ;;
esac

ID="0xesmail.taskbar"
FILES=(manifest.json Taskbar.qml TaskbarModel.js setup-layout.sh uninstall.sh README.md LICENSE)

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS/$ID"
CONFIG="$HOME/.config/omarchy/shell.json"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

in_layout() {
  [[ -f $CONFIG ]] && jq -e --arg id "$1" '
    [.bar.layout // {} | .[]? | .[]? | if type == "object" then .id else . end] | index($id)
  ' "$CONFIG" >/dev/null 2>&1
}

# 1. Copy the plugin files.
mkdir -p "$PLUGINS"
[[ -L $DEST ]] && rm "$DEST"
mkdir -p "$DEST/i18n"
for file in "${FILES[@]}"; do cp "$SRC/$file" "$DEST/"; done
cp "$SRC"/i18n/*.json "$DEST/i18n/"
echo "Copied Taskbar to $DEST"

# 2. Already on the bar: restart the shell to load the new files.
if in_layout "$ID"; then
  echo "Restarting the shell to load the new files."
  omarchy restart shell
  exit 0
fi

# 3. First install: register, place, and seed pins from the dock.
if [[ -f $CONFIG ]]; then
  cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
  echo "Backed up shell.json"
fi

omarchy-shell shell rescanPlugins >/dev/null
for _ in $(seq 20); do
  omarchy plugin list --json 2>/dev/null | jq -e --arg id "$ID" 'any(.[]; .id == $id)' >/dev/null && break
  sleep 0.5
done

if in_layout "omarchy.workspaces"; then
  omarchy plugin enable "$ID" --after omarchy.workspaces
else
  omarchy plugin enable "$ID"
fi

# Taskbar waits 1.5s after loading before it rearranges the bar, so this
# lands first.
if (( KEEP_LAYOUT )); then
  omarchy bar set "$ID" autoLayout false --json >/dev/null
  echo "Keeping your bar layout."
fi

pins=$(jq -c '.dock.pinned // []' "$CONFIG" 2>/dev/null || echo '[]')
if [[ $pins != "[]" ]]; then
  omarchy bar set "$ID" pinned "$pins" --json >/dev/null
  echo "Pinned your dock's apps: $pins"
fi

echo "Done. Right-click the ⊞ button on the bar for Taskbar settings."

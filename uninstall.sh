#!/bin/bash
# Removes Taskbar and puts your bar back the way it was before Taskbar set up
# the Windows layout. The source folder you run this from is left alone.
#
#   ./uninstall.sh                remove and restore the bar (asks first; with
#                                 no terminal to ask in, keeps the bar as is)
#   ./uninstall.sh --yes          remove and restore the bar, without asking
#   ./uninstall.sh --keep-layout  remove, but leave the bar as it is now
set -euo pipefail

ID="0xesmail.taskbar"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$ID"
SNAPSHOT="${XDG_STATE_HOME:-$HOME/.local/state}/$ID/bar-before-layout.json"

RESTORE=ask
for arg in "$@"; do
  case "$arg" in
    --yes|-y) RESTORE=yes ;;
    --keep-layout) RESTORE=no ;;
    *) echo "usage: $0 [--yes|--keep-layout]" >&2; exit 2 ;;
  esac
done

if [[ -f $SNAPSHOT && $RESTORE == ask ]]; then
  saved=$(date -r "$SNAPSHOT" '+%Y-%m-%d %H:%M')
  echo "Your bar layout from before Taskbar was saved on $saved."
  echo "Restoring it undoes any bar changes made since then."
  if [[ -t 0 ]]; then
    read -r -p "Put the bar back the way it was? [Y/n] " answer || answer=""
    [[ $answer =~ ^[Nn] ]] && RESTORE=no || RESTORE=yes
  else
    # Nobody to ask: restoring would throw away changes without consent, so
    # leave the bar alone unless --yes said otherwise.
    RESTORE=no
    echo "No terminal to confirm in, so the bar is left as it is. Run with --yes to restore it."
  fi
fi

# Take Taskbar off the bar through the shell first. Writing shell.json
# before this could let the shell save its older in-memory copy over it.
omarchy plugin disable "$ID" || true
sleep 1

if [[ -f $SNAPSHOT && $RESTORE == yes ]]; then
  bash "$SRC/setup-layout.sh" --restore
elif [[ -f $SNAPSHOT ]]; then
  echo "Kept the bar as it is. The saved layout stays at $SNAPSHOT."
fi

if [[ -L $DEST ]]; then
  rm "$DEST"
elif [[ -f $DEST/manifest.json ]] && jq -e --arg id "$ID" '.id == $id' "$DEST/manifest.json" >/dev/null; then
  rm -r "$DEST"
fi
echo "Removed $DEST"

omarchy-shell shell rescanPlugins >/dev/null || true
echo "Taskbar is uninstalled."

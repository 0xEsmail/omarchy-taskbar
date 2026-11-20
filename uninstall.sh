#!/bin/bash
# Removes Taskbar and can put your bar back the way it was before this
# installation of Taskbar set up the Windows layout. The source folder you
# run this from is left alone.
#
#   ./uninstall.sh                remove; asks whether to restore the bar
#   ./uninstall.sh --yes          remove and restore the bar, without asking
#   ./uninstall.sh --keep-layout  remove, and leave the bar as it is now
#
# Without --yes or --keep-layout it has to ask. If it can't (no terminal, or
# no answer), it stops and changes nothing.
set -euo pipefail

ID="0xesmail.taskbar"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$ID"
CONFIG="${TASKBAR_SHELL_CONFIG:-$HOME/.config/omarchy/shell.json}"
SNAPSHOT="${XDG_STATE_HOME:-$HOME/.local/state}/$ID/bar-before-layout.json"

RESTORE=ask
for arg in "$@"; do
  case "$arg" in
    --yes|-y) RESTORE=yes ;;
    --keep-layout) RESTORE=no ;;
    *) echo "usage: $0 [--yes|--keep-layout]" >&2; exit 2 ;;
  esac
done

# The saved bar belongs to the installation that saved it, which marks its
# bar entry layoutApplied. A saved bar without that entry was left by an
# earlier installation (or one removed without this script); restoring it
# would undo changes made since, so it is never offered, and is deleted.
snapshot_is_current() {
  [[ -f $SNAPSHOT ]] || return 1
  jq -e 'type == "object" and (.layout | type == "object")' "$SNAPSHOT" >/dev/null 2>&1 || return 1
  jq -e --arg id "$ID" '
    [.bar.layout // {} | .[]? | .[]? | select(type == "object" and .id == $id and .layoutApplied == true)]
    | length > 0
  ' "$CONFIG" >/dev/null 2>&1
}

forget_snapshot() {
  rm -f "$SNAPSHOT"
  rmdir "$(dirname "$SNAPSHOT")" 2>/dev/null || true
}

# Decide everything before changing anything.
if snapshot_is_current; then
  if [[ $RESTORE == ask ]]; then
    saved=$(date -r "$SNAPSHOT" '+%Y-%m-%d %H:%M')
    echo "Your bar layout from before Taskbar was saved on $saved."
    echo "Restoring it undoes any bar changes made since then."
    if [[ ! -t 0 ]]; then
      echo "There is no terminal to ask in, so nothing was changed." >&2
      echo "Run again with --yes to restore the bar, or --keep-layout to keep it as it is." >&2
      exit 1
    fi
    if ! read -r -p "Put the bar back the way it was? [Y/n] " answer; then
      echo
      echo "No answer, so nothing was changed." >&2
      exit 1
    fi
    case "${answer,,}" in
      ""|y|yes) RESTORE=yes ;;
      n|no) RESTORE=no ;;
      *) echo "Didn't understand \"$answer\", so nothing was changed." >&2; exit 1 ;;
    esac
  fi
else
  if [[ -f $SNAPSHOT ]]; then
    echo "Ignoring a saved bar from an earlier installation: restoring it would undo changes made since."
    forget_snapshot
  fi
  RESTORE=no
fi

# Take Taskbar off the bar through the shell first. Writing shell.json
# before this could let the shell save its older in-memory copy over it.
omarchy plugin disable "$ID" || true
sleep 1

if [[ $RESTORE == yes ]]; then
  if ! bash "$SRC/setup-layout.sh" --restore; then
    # Keep the plugin folder, so the restore script is still there to retry.
    echo "error: Taskbar is off the bar, but the bar could not be restored." >&2
    echo "Your saved bar is at $SNAPSHOT. Try again with: bash '$SRC/setup-layout.sh' --restore" >&2
    exit 1
  fi
elif [[ -f $SNAPSHOT ]]; then
  # This installation is ending, and so does its restore point.
  forget_snapshot
  echo "Kept the bar as it is."
fi

if [[ -L $DEST ]]; then
  rm "$DEST"
elif [[ -f $DEST/manifest.json ]] && jq -e --arg id "$ID" '.id == $id' "$DEST/manifest.json" >/dev/null; then
  # -f: a copy installed with `omarchy plugin add` is a git clone, whose
  # read-only .git objects would otherwise make rm stop and ask about each
  # one. The manifest check above is what keeps this to Taskbar's folder.
  rm -rf "$DEST"
fi
echo "Removed $DEST"

omarchy-shell shell rescanPlugins >/dev/null || true
echo "Taskbar is uninstalled."

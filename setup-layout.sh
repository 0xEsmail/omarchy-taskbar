#!/bin/bash
# Windows-style layout for Taskbar: bar at the bottom, Taskbar alone in the
# center, clock in the bottom-right corner.
#
#   ./setup-layout.sh            apply once (what Taskbar runs on first load)
#   ./setup-layout.sh --force    apply again ("Apply Windows layout" in ⊞ menu)
#   ./setup-layout.sh --restore  put the bar back as it was before Taskbar
#
# Taskbar runs it the first time it loads (unless its autoLayout setting is
# false), then records layoutApplied on its bar entry so it never rearranges
# the bar again on its own.
#
# Before the first change of each installation it saves the bar as it was,
# minus Taskbar itself, to $XDG_STATE_HOME/0xesmail.taskbar/bar-before-layout.json,
# replacing any copy an earlier installation left. Re-applying within the
# same installation keeps that copy. --restore puts back only the "bar" part
# of shell.json; uninstall.sh runs it after checking the copy belongs to the
# installation being removed. shell.json is backed up before every change.
set -uo pipefail

ID="0xesmail.taskbar"
CONFIG="${TASKBAR_SHELL_CONFIG:-$HOME/.config/omarchy/shell.json}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$ID"
SNAPSHOT="$STATE_DIR/bar-before-layout.json"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/$ID.layout.lock"

MODE="apply"
case "${1:-}" in
  --force) MODE="force" ;;
  --restore) MODE="restore" ;;
  "") ;;
  *) echo "usage: $0 [--force|--restore]" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
[[ -f $CONFIG ]] || exit 0

backup_config() {
  cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
}

is_bar_layout() {
  jq -e 'type == "object" and (.layout | type == "object")' "$1" >/dev/null 2>&1
}

# Every bar section with this plugin's entry taken out.
WITHOUT_TASKBAR='
  .layout |= with_entries(.value |= (
    if type == "array"
    then map(select((if type == "object" then .id else . end) != $id))
    else . end))'

if [[ $MODE == "restore" ]]; then
  exec 9>"$LOCK"
  flock -w 5 9 || { echo "error: the layout script is already running" >&2; exit 1; }
  if [[ ! -f $SNAPSHOT ]]; then
    echo "No saved bar layout to restore."
    exit 0
  fi
  is_bar_layout "$SNAPSHOT" ||
    { echo "error: $SNAPSHOT is not a saved bar layout" >&2; exit 1; }
  backup_config || { echo "error: could not back up $CONFIG; leaving the bar alone" >&2; exit 1; }
  tmp=$(mktemp "$CONFIG.XXXXXX")
  jq --arg id "$ID" --slurpfile bar "$SNAPSHOT" ".bar = (\$bar[0] | $WITHOUT_TASKBAR)" "$CONFIG" >"$tmp" &&
    mv "$tmp" "$CONFIG" || { rm -f "$tmp"; echo "error: could not restore the bar" >&2; exit 1; }
  rm -f "$SNAPSHOT"
  rmdir "$STATE_DIR" 2>/dev/null
  echo "Restored the bar as it was before Taskbar."
  exit 0
fi

# One bar per monitor loads the widget; only the first gets to run this.
exec 9>"$LOCK"
flock -n 9 || exit 0

entry_value() {
  jq -r --arg id "$ID" --arg key "$1" '
    [.bar.layout // {} | .[]? | .[]? | select(type == "object" and .id == $id)][0]
    | if type == "object" and has($key) then .[$key] | tostring else "unset" end
  ' "$CONFIG"
}

has() {
  jq -e --arg id "$1" '
    [.bar.layout // {} | .[]? | .[]? | if type == "object" then .id else . end] | index($id)
  ' "$CONFIG" >/dev/null
}

ids_in() {
  jq -r --arg s "$1" '.bar.layout[$s] // [] | .[] | if type == "object" then .id else . end' "$CONFIG"
}

has "$ID" || exit 0
if [[ $MODE == "apply" ]]; then
  [[ $(entry_value layoutApplied) == "true" ]] && exit 0
  [[ $(entry_value autoLayout) == "false" ]] && exit 0
fi

backup_config || { echo "error: could not back up $CONFIG; leaving the bar alone" >&2; exit 1; }

# The restore point: the bar as it was before this installation of Taskbar
# rearranged it. Uninstalling promises to put it back, so without a good copy
# nothing below may run.
#
# It belongs to one installation. The bar entry marked layoutApplied is this
# installation having already saved it, so that copy is kept (a --force
# re-apply must not overwrite the original). Any other run is a new
# activation, after a fresh install or a reinstall, and saves the bar as it
# is now, replacing whatever an earlier installation left behind. Restoring
# can then never reach back past the current installation.
#
# Written to a temp file and checked before it takes the real name, so a
# failure never leaves a half-written restore point behind.
save_snapshot() {
  local tmp=""
  if mkdir -p "$STATE_DIR" &&
     tmp=$(mktemp "$STATE_DIR/.bar-before-layout.XXXXXX") &&
     jq --arg id "$ID" ".bar // {} | $WITHOUT_TASKBAR" "$CONFIG" >"$tmp" &&
     is_bar_layout "$tmp" &&
     mv "$tmp" "$SNAPSHOT"; then
    return 0
  fi
  [[ -n $tmp ]] && rm -f "$tmp"
  return 1
}

if [[ $(entry_value layoutApplied) == "true" && -f $SNAPSHOT ]]; then
  is_bar_layout "$SNAPSHOT" ||
    { echo "error: the saved bar at $SNAPSHOT is damaged; leaving the bar alone" >&2; exit 1; }
else
  save_snapshot ||
    { echo "error: could not save the bar to $SNAPSHOT; leaving the bar alone" >&2; exit 1; }
fi

omarchy bar position bottom

# Anything in the center box, or hanging off its edges, would hug the taskbar
# and shift as apps open and close. Move it to the start of the right
# section, keeping its order.
index=0
for section in centerBegin center centerEnd; do
  mapfile -t ids < <(ids_in "$section")
  for id in "${ids[@]}"; do
    [[ -z $id || $id == "$ID" || $id == "omarchy.clock" ]] && continue
    omarchy bar move "$id" --section right --index "$index" && index=$((index + 1))
  done
done

omarchy bar move "$ID" --section center
has omarchy.clock && omarchy bar move omarchy.clock --section right --index 9999

# Icons only: the title already shows in "Active window", or not at all,
# as on Windows 11.
omarchy bar set "$ID" labels none

# Out of the center box, the indicators only reveal inactive icons on hover
# of the bar's middle, which is now the taskbar. Keep them visible.
has omarchy.indicators && omarchy bar set omarchy.indicators alwaysShow true --json

omarchy bar set "$ID" layoutApplied true --json
echo "Applied the Windows layout."

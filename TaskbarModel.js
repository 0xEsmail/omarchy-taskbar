// Taskbar state that does not need Quickshell: which apps show, in what
// order, and what a click on one should do. Kept free of QML so it can be
// tested with plain node (see tests/model.test.js).

var MINIMIZED_WORKSPACE = "special:minimized"

function normalizeId(value) {
  var id = String(value || "").trim()
  if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
  return id
}

function pinnedIds(list) {
  var source = Array.isArray(list) ? list : []
  var ids = []
  for (var i = 0; i < source.length; i++) {
    var id = normalizeId(source[i])
    if (id && ids.indexOf(id) === -1) ids.push(id)
  }
  return ids
}

function isMinimizedWorkspace(name) {
  return String(name || "") === MINIMIZED_WORKSPACE
}

// Which windows the taskbar lists. Minimized windows always show (the taskbar
// is the way back to them); other special workspaces such as the scratchpad
// stay out. filter is "all", "monitor" (windows on this bar's monitor) or
// "workspace" (windows on the workspace this bar's monitor is showing).
function isTaskbarWindow(window, filter, monitorName, workspaceId) {
  if (!window || !window.key) return false
  if (window.minimized === true) return true
  if (!(window.workspaceId >= 1)) return false
  if (filter === "workspace") return window.workspaceId === workspaceId
  if (filter === "monitor") return !monitorName || window.monitorName === monitorName
  return true
}

// Pinned apps first, in pin order, running or not; then running apps that
// are not pinned, in the order their first window appeared.
function buildItems(pinned, windows, filter, monitorName, workspaceId) {
  var items = []
  var byKey = {}

  function itemFor(key, isPinned) {
    if (!byKey[key]) {
      byKey[key] = { key: key, pinned: isPinned, windows: [] }
      items.push(byKey[key])
    }
    return byKey[key]
  }

  for (var i = 0; i < (pinned || []).length; i++) {
    if (pinned[i]) itemFor(pinned[i], true)
  }
  for (var j = 0; j < (windows || []).length; j++) {
    var window = windows[j]
    if (isTaskbarWindow(window, filter, monitorName, workspaceId)) itemFor(window.key, false).windows.push(window)
  }
  return items
}

// Applies the session order: an app keeps its slot while it stays on the
// taskbar; newcomers go at the end.
function orderItems(items, order) {
  var byKey = {}
  for (var i = 0; i < (items || []).length; i++) byKey[items[i].key] = items[i]
  var result = []
  var placed = {}
  for (var j = 0; j < (order || []).length; j++) {
    var key = order[j]
    if (byKey[key] && !placed[key]) {
      result.push(byKey[key])
      placed[key] = true
    }
  }
  for (var k = 0; k < (items || []).length; k++) {
    if (!placed[items[k].key]) result.push(items[k])
  }
  return result
}

function orderWithKeyAt(order, key, index) {
  var keys = (order || []).filter(function(other) { return other !== key })
  keys.splice(Math.max(0, Math.min(keys.length, index)), 0, key)
  return keys
}

// Pins to save for a given order: pinned apps in that order, then pins the
// taskbar is not currently showing (app not installed) where they were.
function pinsInOrder(order, pinnedSet, allPinned) {
  var result = (order || []).filter(function(key) { return pinnedSet[key] === true })
  for (var i = 0; i < (allPinned || []).length; i++) {
    if (result.indexOf(allPinned[i]) === -1 && (order || []).indexOf(allPinned[i]) === -1) result.push(allPinned[i])
  }
  return result
}

// Which window a click brings forward: windows on the visible workspace
// first, then minimized ones, then those elsewhere. Clicking again while one
// is focused moves on to the next. Windows are { workspaceId, minimized, activated }.
function pickWindow(windows, workspaceId) {
  var list = windows || []
  if (list.length === 0) return -1

  function rank(window) {
    if (window.minimized) return 1
    return window.workspaceId === workspaceId ? 0 : 2
  }

  var order = list.map(function(window, index) { return index })
  order.sort(function(a, b) { return rank(list[a]) - rank(list[b]) || a - b })

  for (var i = 0; i < order.length; i++) {
    if (list[order[i]].activated) return order[(i + 1) % order.length]
  }
  return order[0]
}

// What a left click on an app does, Windows style:
//   not running                      -> launch
//   its only window has focus        -> minimize (when clickToMinimize)
//   otherwise                        -> focus / cycle to the next window
// Returns { action: "launch" | "minimize" | "focus", index }.
function clickAction(windows, workspaceId, clickToMinimize) {
  var list = windows || []
  if (list.length === 0) return { action: "launch", index: -1 }
  if (clickToMinimize && list.length === 1 && list[0].activated && !list[0].minimized)
    return { action: "minimize", index: 0 }
  return { action: "focus", index: pickWindow(list, workspaceId) }
}

// The window index a scroll step lands on, wrapping around.
function stepWindow(windows, step) {
  var list = windows || []
  if (list.length === 0) return -1
  var current = -1
  for (var i = 0; i < list.length; i++) if (list[i].activated) { current = i; break }
  if (current < 0) return step > 0 ? 0 : list.length - 1
  return ((current + step) % list.length + list.length) % list.length
}

// The slot a dragged button would land in: the first slot whose center lies
// past the pointer, counted once the dragged slot has left its place.
// centers are the slots' centers along the bar, in order.
function dropIndex(centers, fromIndex, pointer) {
  var count = (centers || []).length
  if (count === 0) return fromIndex
  var target = count
  for (var i = 0; i < count; i++) {
    if (pointer < centers[i]) { target = i; break }
  }
  if (target > fromIndex) target -= 1
  return Math.max(0, Math.min(count - 1, target))
}

// A terminal app's window carries the app id its launcher gave the terminal,
// which no desktop entry names as its class. The entry that passes that app
// id claims it, and so does a terminal entry for the command Omarchy's TUI
// launcher named it after (org.omarchy.nvim for nvim). Entries are
// { id, execString, command, runInTerminal }.
function claimingEntryId(appId, entries) {
  var id = String(appId || "")
  if (!id) return ""
  var list = entries || []
  var flag = "--app-id=" + id
  for (var i = 0; i < list.length; i++) {
    var words = String(list[i].execString || "").split(/\s+/)
    if (words.indexOf(flag) >= 0) return list[i].id
  }
  if (id.indexOf("org.omarchy.") !== 0) return ""
  var command = id.slice("org.omarchy.".length)
  for (var j = 0; j < list.length; j++) {
    var program = String((list[j].command || [])[0] || "")
    if (list[j].runInTerminal && program.slice(program.lastIndexOf("/") + 1) === command) return list[j].id
  }
  return ""
}

function hyprAddress(address) {
  var value = String(address || "")
  if (!value) return ""
  return value.indexOf("0x") === 0 ? value : "0x" + value
}

if (typeof module !== "undefined") {
  module.exports = {
    MINIMIZED_WORKSPACE: MINIMIZED_WORKSPACE,
    normalizeId: normalizeId,
    pinnedIds: pinnedIds,
    isMinimizedWorkspace: isMinimizedWorkspace,
    isTaskbarWindow: isTaskbarWindow,
    buildItems: buildItems,
    orderItems: orderItems,
    orderWithKeyAt: orderWithKeyAt,
    pinsInOrder: pinsInOrder,
    pickWindow: pickWindow,
    clickAction: clickAction,
    stepWindow: stepWindow,
    dropIndex: dropIndex,
    claimingEntryId: claimingEntryId,
    hyprAddress: hyprAddress
  }
}

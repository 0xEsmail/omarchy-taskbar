import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "TaskbarModel.js" as Model

// A Windows-style taskbar that lives inside the Omarchy bar: pinned apps and
// running apps side by side. Click to launch, focus, cycle or minimize; hover
// for live previews; right-click for a jump list; drag to reorder.
//
// Author: 0xEsmail · MIT License · https://github.com/0xEsmail/omarchy-taskbar
BarWidget {
  id: root
  moduleName: "0xesmail.taskbar"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------- settings

  readonly property string labelsMode: {
    var value = String(setting("labels", "focused"))
    return ["none", "focused", "all"].indexOf(value) >= 0 ? value : "focused"
  }
  readonly property int maxLabelWidth: Math.max(60, Math.min(600, Number(setting("maxLabelWidth", 180)) || 180))
  readonly property string filterMode: {
    var value = String(setting("filter", "all"))
    return ["all", "monitor", "workspace"].indexOf(value) >= 0 ? value : "all"
  }
  readonly property bool clickToMinimize: setting("clickToMinimize", true) !== false
  readonly property bool previewsEnabled: setting("previews", true) !== false
  readonly property bool showAppsButton: setting("showAppsButton", true) !== false
  readonly property string appsCommand: String(setting("appsCommand", "omarchy-shell omarchy.dock apps"))
  readonly property bool autoLayout: setting("autoLayout", true) !== false
  readonly property bool layoutApplied: setting("layoutApplied", false) === true

  // ------------------------------------------------------------- first run

  // The first time Taskbar loads, it sets the bar up Windows style: bar at
  // the bottom, Taskbar in the center, clock in the corner. setup-layout.sh
  // records layoutApplied when done, so this happens once; turn it off with
  // autoLayout: false. Plugins cannot move other widgets themselves, so the
  // script does it through Omarchy's own `omarchy bar` commands.
  readonly property string layoutScript: decodeURIComponent(String(Qt.resolvedUrl("setup-layout.sh")).replace(/^file:\/\//, ""))

  function applyLayout(force) {
    Util.execDetached("bash " + Util.shellQuote(root.layoutScript) + (force ? " --force" : ""))
  }

  Timer {
    // Let the bar settle before rearranging it.
    interval: 1500
    running: root.autoLayout && !root.layoutApplied && !!root.bar
    onTriggered: root.applyLayout(false)
  }

  // ------------------------------------------------------------- geometry

  readonly property color fg: bar && bar.barForeground && bar.barForeground.a > 0 ? bar.barForeground : Commons.Color.bar.text
  readonly property string fontFamily: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property string barPosition: bar ? bar.position : "top"
  readonly property int iconSize: Math.max(12, Math.round(barSize * 0.66))
  readonly property int slotPadding: Style.space(5)
  readonly property int labelGap: Style.space(6)
  readonly property real idleOpacity: 0.6

  // ------------------------------------------------------------- monitor

  readonly property var hostWindow: QsWindow.window
  readonly property var hyprMonitor: hostWindow && hostWindow.screen ? Hyprland.monitorFor(hostWindow.screen) : null
  readonly property string monitorName: hyprMonitor ? String(hyprMonitor.name || "") : ""
  readonly property int monitorWorkspaceId: hyprMonitor && hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
  readonly property int focusedWorkspaceId: Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace
    ? Hyprland.focusedMonitor.activeWorkspace.id : -1

  // ------------------------------------------------------------- pins

  // A pin change shows at once; the saved config catches up after.
  property var pendingPins: null
  onSettingsChanged: pendingPins = null
  readonly property var pinnedKeys: pendingPins || Model.pinnedIds(setting("pinned", []))

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  function saveSettings(changes) {
    var next = {}
    var current = root.settings || {}
    for (var k in current) if (k !== "id") next[k] = current[k]
    for (var c in changes) next[c] = changes[c]
    var shellApi = root.bar ? root.bar.shell : null
    if (shellApi && typeof shellApi.updateEntryInline === "function") shellApi.updateEntryInline(root.moduleName, next)
    else console.warn("0xesmail.taskbar: cannot save settings, no shell API")
  }

  function savePins(pins) {
    root.pendingPins = pins
    root.saveSettings({ pinned: pins })
  }

  // The session order of apps, as desktop ids, set by Move left/right and
  // by pinning.
  property var order: []

  function shownKeys() {
    return root.items.map(function(item) { return item.key })
  }

  function placeAt(key, index, pin) {
    if (!key) return
    root.order = Model.orderWithKeyAt(root.shownKeys(), key, index)
    var pinnedSet = {}
    root.pinnedKeys.forEach(function(other) { pinnedSet[other] = true })
    if (pin) pinnedSet[key] = true
    var pins = Model.pinsInOrder(root.order, pinnedSet, root.pinnedKeys)
    if (JSON.stringify(pins) !== JSON.stringify(root.pinnedKeys)) root.savePins(pins)
  }

  function setPinned(key, pinned) {
    if (!key) return
    if (pinned) {
      if (root.isPinned(key)) return
      var shown = root.shownKeys()
      var at = shown.indexOf(key)
      // Pinning keeps a running app where it is; a new one goes at the end.
      root.placeAt(key, at >= 0 ? at : shown.length, true)
    } else {
      root.savePins(root.pinnedKeys.filter(function(other) { return other !== key }))
    }
  }

  // ------------------------------------------------------------- apps

  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = Model.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  function entryFor(item) {
    return item ? DesktopEntries.byId(item.key) : null
  }

  function appName(item) {
    var entry = root.entryFor(item)
    if (entry && entry.name) return String(entry.name)
    return item ? String(item.key) : ""
  }

  function iconSource(name) {
    var value = String(name || "")
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    var themed = value ? Quickshell.iconPath(value, true) : ""
    if (!themed && value) themed = Quickshell.iconPath(value.toLowerCase(), true)
    return themed || Quickshell.iconPath("application-x-executable", true)
  }

  function iconFor(item) {
    var entry = root.entryFor(item)
    return root.iconSource(entry && entry.icon ? entry.icon : (item ? item.key : ""))
  }

  function windowTitle(window) {
    if (!window) return ""
    var title = window.hypr && window.hypr.title ? window.hypr.title : (window.toplevel ? window.toplevel.title : "")
    return String(title || "")
  }

  // Every app on the taskbar: pinned first, then running, in session order.
  readonly property var items: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = root.pinnedKeys.filter(function(id) { return !!DesktopEntries.byId(id) })
    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var hypr = toplevels[i]
      var toplevel = hypr.wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForAppId(toplevel.appId)
      // Helpers that hide their launcher entry stay off the taskbar.
      if (entry && entry.noDisplay) continue
      var workspace = hypr.workspace
      windows.push({
        key: entry ? entry.id : String(toplevel.appId),
        workspaceId: workspace ? workspace.id : -1,
        workspaceName: workspace ? String(workspace.name || "") : "",
        monitorName: workspace && workspace.monitor ? String(workspace.monitor.name || "") : "",
        minimized: !!workspace && Model.isMinimizedWorkspace(workspace.name),
        address: hypr.address,
        toplevel: toplevel,
        hypr: hypr
      })
    }
    return Model.orderItems(
      Model.buildItems(pinned, windows, root.filterMode, root.monitorName, root.monitorWorkspaceId),
      root.order)
  }

  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < root.items.length; i++) byKey[root.items[i].key] = root.items[i]
    return byKey
  }

  function itemFor(key) {
    return root.itemsByKey[key] || null
  }

  // Slots follow this model rather than the items list, so a button survives
  // a window opening or closing instead of being rebuilt under the pointer.
  ListModel { id: itemModel }

  onItemsChanged: syncItemModel()
  Component.onCompleted: {
    syncItemModel()
    root.barHost = root.findBarHost()
    Qt.callLater(root.liftAboveBarDrag)
  }

  function syncItemModel() {
    var keys = root.shownKeys()
    for (var i = 0; i < keys.length; i++) {
      if (i < itemModel.count && itemModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < itemModel.count; j++) {
        if (itemModel.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) itemModel.move(found, i, 1)
      else itemModel.insert(i, { key: keys[i] })
    }
    if (itemModel.count > keys.length) itemModel.remove(keys.length, itemModel.count - keys.length)
    root.settleLaunches()
  }

  // ------------------------------------------------------------- launching

  // An app launched from the taskbar pulses until a new window of it shows
  // up, or for ten seconds if none does.
  property var launches: ({})

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      var item = root.itemsByKey[key]
      var count = item ? item.windows.length : 0
      if (count > launch.windows || now - launch.at > 10000) changed = true
      else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function launch(item) {
    var entry = root.entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    // Terminal apps go through Omarchy's TUI launcher, everything else
    // through gtk-launch in its own scope, as the app launcher does.
    if (entry.runInTerminal) {
      var words = (entry.command || []).filter(function(word) { return !/^%[a-zA-Z]$/.test(String(word)) })
      if (words.length > 0) {
        Util.execDetached("omarchy-launch-tui " + words.map(function(word) { return Util.shellQuote(word) }).join(" "))
        return
      }
    }
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(entry.id + ".desktop"))
  }

  // ------------------------------------------------------------- windows

  // Hyprland warps the pointer onto a window it focuses (and on a workspace
  // change), which would yank the mouse off the taskbar after every click.
  // Run the steps as one Lua eval with cursor.no_warps switched on around
  // them, restoring the user's own value afterwards.
  function warplessLua(steps) {
    return "local prev = hl.get_config(\"cursor.no_warps\") "
      + "if prev == nil then prev = false end "
      + "hl.config({ cursor = { no_warps = true } }) "
      + "local ok, err = pcall(function() "
      + steps.map(function(step) { return "hl.dispatch(" + step + ")" }).join(" ")
      + " end) "
      + "hl.config({ cursor = { no_warps = prev } }) "
      + "if not ok then error(err) end"
  }

  function dispatch(steps, after) {
    var command = "hyprctl eval " + Util.shellQuote(root.warplessLua(steps)) + " >/dev/null"
    if (after && after.length > 0) command += "; sleep 0.4; hyprctl eval " + Util.shellQuote(root.warplessLua(after)) + " >/dev/null"
    Util.execDetached(command)
  }

  function windowTarget(window) {
    return "window = \"address:" + Model.hyprAddress(window.address) + "\""
  }

  // Brings a window forward, focused and on top. A minimized one first comes
  // back to the workspace in front of the user.
  function focusWindow(window) {
    if (!window) return
    if (!Model.hyprAddress(window.address)) {
      if (window.toplevel) window.toplevel.activate()
      return
    }
    var target = root.windowTarget(window)
    var steps = []
    var after = []
    if (window.minimized) {
      var workspace = root.focusedWorkspaceId
      if (!(workspace >= 1)) return
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    root.dispatch(steps, after)
  }

  // Parks a window on the minimized special workspace, the same place
  // Omarchy's own dock minimizes to, and hands focus back to its workspace.
  function minimizeWindow(window) {
    if (!window || window.minimized || !Model.hyprAddress(window.address)) return
    var target = root.windowTarget(window)
    var workspace = window.workspaceId
    var steps = []
    if (workspace >= 1) steps.push("hl.dsp.window.tag({ tag = \"+omarchy-minimized-from-" + workspace + "\", " + target + " })")
    steps.push("hl.dsp.window.move({ workspace = \"" + Model.MINIMIZED_WORKSPACE + "\", follow = false, " + target + " })")
    if (workspace >= 1) steps.push("hl.dsp.focus({ workspace = \"" + workspace + "\" })")
    root.dispatch(steps, [])
  }

  function moveWindowHere(window) {
    var workspace = root.focusedWorkspaceId
    if (!window || !(workspace >= 1) || !Model.hyprAddress(window.address)) return
    root.dispatch(["hl.dsp.window.move({ workspace = \"" + workspace + "\", follow = false, " + root.windowTarget(window) + " })"], [])
  }

  function closeWindow(window) {
    if (window && window.toplevel) window.toplevel.close()
  }

  function windowStates(item) {
    return item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized, activated: !!window.toplevel && window.toplevel.activated }
    })
  }

  function activate(item) {
    if (!item) return
    var result = Model.clickAction(root.windowStates(item), root.focusedWorkspaceId, root.clickToMinimize)
    if (result.action === "launch") root.launch(item)
    else if (result.action === "minimize") root.minimizeWindow(item.windows[result.index])
    else root.focusWindow(item.windows[result.index])
  }

  function cycle(item, step) {
    if (!item || item.windows.length === 0) return
    var index = Model.stepWindow(root.windowStates(item), step)
    if (index >= 0) root.focusWindow(item.windows[index])
  }

  function activateAt(index) {
    var item = root.items[index]
    if (item) root.activate(item)
  }

  function launchAt(index) {
    var item = root.items[index]
    if (item) root.launch(item)
  }

  // ------------------------------------------------------------- IPC

  // omarchy-shell 0xesmail.taskbar activate 1   -> click the first app
  // omarchy-shell 0xesmail.taskbar launch 2     -> new window of the second app
  // omarchy-shell 0xesmail.taskbar pin firefox  -> pin by desktop id
  // omarchy-shell 0xesmail.taskbar pinFocused   -> pin the focused window's app
  ShellIpc {
    target: "0xesmail.taskbar"

    function activate(position: int): void { root.activateAt(position - 1) }
    function launch(position: int): void { root.launchAt(position - 1) }
    function pin(desktopId: string): void { root.setPinned(Model.normalizeId(desktopId), true) }
    function unpin(desktopId: string): void { root.setPinned(Model.normalizeId(desktopId), false) }
    function pinFocused(): void {
      var toplevel = ToplevelManager.activeToplevel
      var entry = toplevel ? root.entryForAppId(toplevel.appId) : null
      if (entry) root.setPinned(entry.id, true)
    }
  }

  // ------------------------------------------------------------- reorder

  // Drag an app, with the left or right button, to move it. A click that
  // does not move still clicks, and the right-click menu also has
  // Move left / Move right.
  //
  // The bar lays a handler over every widget that takes any left-button
  // drag, to move the widget or remove it when dragged off the bar. Taskbar
  // lifts its own slot's widget area above that handler (liftAboveBarDrag),
  // so its icons get their presses first. If a future bar is built
  // differently and the lift finds nothing, left-drags go back to moving
  // the widget, and right-drag still reorders.
  property Item liftedArea: null
  property Item barHost: null

  // The bar slot holding this widget: the ancestor with a widgetHolder.
  function findBarSlot() {
    for (var p = root.parent; p; p = p.parent) {
      if ("widgetHolder" in p && "widgetKey" in p && p.widgetHolder) return p
    }
    return null
  }

  // The bar's per-widget host, which moves between slots.
  function findBarHost() {
    for (var p = root.parent; p; p = p.parent) {
      if ("owner" in p && "pool" in p && "activeItem" in p) return p
    }
    return null
  }

  function liftAboveBarDrag() {
    var slot = root.findBarSlot()
    var holder = slot ? slot.widgetHolder : null
    // The widget area is the holder's parent and a sibling of the bar's drag
    // handler; only siblings stack against each other.
    var area = holder && holder.parent && holder.parent.parent === slot ? holder.parent : null
    if (root.liftedArea && root.liftedArea !== area) root.liftedArea.z = 0
    if (area) area.z = 1
    root.liftedArea = area
  }

  Connections {
    target: root.barHost
    ignoreUnknownSignals: true
    // Moved to another section: lift the new slot's area instead.
    function onParentChanged() { Qt.callLater(root.liftAboveBarDrag) }
  }

  Component.onDestruction: if (root.liftedArea) root.liftedArea.z = 0

  property int dragIndex: -1
  property int dropIndex: -1
  property real dragOffset: 0
  readonly property bool dragging: dragIndex >= 0

  function slotCenters() {
    var centers = []
    for (var i = 0; i < appRepeater.count; i++) {
      var slot = appRepeater.itemAt(i)
      if (slot) centers.push(root.vertical ? slot.y + slot.height / 2 : slot.x + slot.width / 2)
    }
    return centers
  }

  function startDrag(index) {
    root.closeMenu()
    root.closePreview()
    // The landing slot first: with only the dragged slot set, every slot
    // before it would count as in between for a moment.
    root.dropIndex = index
    root.dragIndex = index
  }

  function endDrag() {
    root.dragIndex = -1
    root.dropIndex = -1
    root.dragOffset = 0
  }

  function moveBy(key, delta) {
    var shown = root.shownKeys()
    var from = shown.indexOf(key)
    if (from < 0) return
    var to = Math.max(0, Math.min(shown.length - 1, from + delta))
    if (to !== from) root.placeAt(key, to, false)
  }

  // ------------------------------------------------------------- popups

  property Item menuSlot: null
  property bool settingsMenuOpen: false
  readonly property bool menuOpen: menuSlot !== null || settingsMenuOpen
  property Item menuAnchor: null

  function openMenu(slot) {
    root.closePreview()
    root.settingsMenuOpen = false
    root.menuAnchor = slot
    root.menuSlot = slot
  }

  function openSettingsMenu(anchor) {
    root.closePreview()
    root.menuSlot = null
    root.menuAnchor = anchor
    root.settingsMenuOpen = true
  }

  function closeMenu() {
    root.menuSlot = null
    root.settingsMenuOpen = false
  }

  QtObject {
    id: menuOwner
    function close() { root.closeMenu() }
  }

  property Item previewSlot: null
  property Item pendingPreviewSlot: null
  property bool previewOpen: false

  QtObject {
    id: previewOwner
    function close() { root.closePreview() }
  }

  function closePreview() {
    previewOpenTimer.stop()
    previewCloseTimer.stop()
    root.previewOpen = false
  }

  function tooltipFor(slot) {
    if (!slot || !slot.item) return ""
    var name = root.appName(slot.item)
    var count = slot.item.windows.length
    if (count === 0) return name
    if (count === 1) return root.windowTitle(slot.item.windows[0]) || name
    return strings.tn("tooltip.windows", count).arg(name).arg(Commons.I18n.formatNumber(count))
  }

  function hoverSlot(slot) {
    previewCloseTimer.stop()
    if (root.menuOpen || root.dragging) return
    var canPreview = root.previewsEnabled && slot.running
    if (root.previewOpen) {
      if (canPreview) {
        root.previewSlot = slot
        if (previewCard.anchor && typeof previewCard.anchor.updateAnchor === "function") previewCard.anchor.updateAnchor()
        return
      }
      root.closePreview()
    }
    if (canPreview) {
      root.pendingPreviewSlot = slot
      previewOpenTimer.restart()
    } else if (root.bar) {
      root.bar.showTooltip(slot, root.tooltipFor(slot))
    }
  }

  function unhoverSlot(slot) {
    if (root.bar) root.bar.hideTooltip(slot)
    if (root.pendingPreviewSlot === slot) previewOpenTimer.stop()
    if (root.previewOpen) previewCloseTimer.restart()
  }

  Timer {
    id: previewOpenTimer
    interval: 400
    onTriggered: {
      var slot = root.pendingPreviewSlot
      if (!slot || !slot.hovered || !slot.running || root.menuOpen || root.dragging) return
      root.previewSlot = slot
      root.previewOpen = true
    }
  }

  Timer {
    id: previewCloseTimer
    interval: 250
    onTriggered: {
      if (previewCard.containsMouse) return
      if (root.previewSlot && root.previewSlot.hovered) return
      root.previewOpen = false
    }
  }

  // Another bar panel opening takes over; ours step aside.
  Connections {
    target: root.bar
    ignoreUnknownSignals: true
    function onActivePopoutChanged() {
      var active = root.bar ? root.bar.activePopout : null
      if (!active) return
      if (active !== menuOwner && root.menuOpen) root.closeMenu()
      if (active !== previewOwner && root.previewOpen) root.closePreview()
    }
  }

  // ------------------------------------------------------------- layout

  implicitWidth: root.vertical ? root.barSize : strip.implicitWidth
  implicitHeight: root.vertical ? strip.implicitHeight : root.barSize

  // Takes left presses in the gaps between icons, so a stray drag there
  // cannot pick up the whole widget and drop it off the bar.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
  }

  Grid {
    id: strip
    columns: root.vertical ? 1 : appRepeater.count + 1
    spacing: Style.space(2)

    AppsButton {
      visible: root.showAppsButton
    }

    Repeater {
      id: appRepeater
      model: itemModel
      delegate: AppButton {}
    }
  }

  // Where a dragged app will land: a thin accent line between two slots.
  Rectangle {
    readonly property Item target: root.dragging && root.dropIndex !== root.dragIndex ? appRepeater.itemAt(root.dropIndex) : null
    readonly property bool after: root.dropIndex > root.dragIndex
    visible: !!target
    z: 3
    color: Commons.Color.accent
    radius: 1
    width: root.vertical ? root.barSize - Style.space(8) : 2
    height: root.vertical ? 2 : root.barSize - Style.space(8)
    x: !target ? 0 : root.vertical ? Style.space(4) : strip.x + target.x + (after ? target.width : 0) - 1
    y: !target ? 0 : root.vertical ? strip.y + target.y + (after ? target.height : 0) - 1 : Style.space(4)
  }

  // ------------------------------------------------------------- buttons

  component SlotBackground: Rectangle {
    property bool hovered: false
    property bool pressed: false
    property bool active: false
    property bool urgent: false

    anchors.fill: parent
    anchors.topMargin: root.vertical ? 0 : Style.space(2)
    anchors.bottomMargin: root.vertical ? 0 : Style.space(2)
    anchors.leftMargin: root.vertical ? Style.space(2) : 0
    anchors.rightMargin: root.vertical ? Style.space(2) : 0
    radius: Math.max(3, Style.cornerRadius)
    color: urgent ? Util.alpha(Commons.Color.urgent, hovered ? 0.5 : 0.35)
      : pressed ? Util.alpha(root.fg, 0.2)
      : hovered ? Util.alpha(root.fg, 0.12)
      : active ? Util.alpha(root.fg, 0.08)
      : "transparent"

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
  }

  // A start-style button: left opens the app grid, right opens settings.
  component AppsButton: Item {
    id: appsButton

    width: root.vertical ? root.barSize : root.iconSize + root.slotPadding * 2
    height: root.vertical ? root.iconSize + root.slotPadding * 2 : root.barSize

    SlotBackground {
      hovered: appsMouse.containsMouse
      pressed: appsMouse.pressed
      active: root.settingsMenuOpen
    }

    Grid {
      readonly property int square: Math.max(3, Math.round(root.iconSize * 0.36))
      anchors.centerIn: parent
      columns: 2
      spacing: Math.max(1, Math.round(root.iconSize * 0.1))
      scale: appsMouse.pressed ? 0.88 : 1

      Behavior on scale { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }

      Repeater {
        model: 4
        delegate: Rectangle {
          width: parent.square
          height: parent.square
          radius: Math.max(1, Math.round(parent.square * 0.2))
          color: appsMouse.containsMouse ? Commons.Color.accent : root.fg
        }
      }
    }

    MouseArea {
      id: appsMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(event) {
        if (root.bar) root.bar.hideTooltip(appsButton)
        if (event.button === Qt.RightButton) {
          if (root.settingsMenuOpen) root.closeMenu()
          else root.openSettingsMenu(appsButton)
          return
        }
        root.closeMenu()
        if (root.appsCommand && root.bar) root.bar.run(root.appsCommand)
      }
      onEntered: if (root.bar && !root.menuOpen) root.bar.showTooltip(appsButton, strings.t("apps.tooltip"))
      onExited: if (root.bar) root.bar.hideTooltip(appsButton)
    }
  }

  component AppButton: Item {
    id: slot

    required property int index
    required property string key

    readonly property var item: root.itemFor(key)
    readonly property var windows: item ? item.windows : []
    readonly property int windowCount: windows.length
    readonly property bool running: windowCount > 0
    readonly property var focusedWindow: {
      for (var i = 0; i < windows.length; i++) {
        if (windows[i].toplevel && windows[i].toplevel.activated) return windows[i]
      }
      return null
    }
    readonly property bool focused: focusedWindow !== null
    readonly property bool urgent: {
      for (var i = 0; i < windows.length; i++) {
        if (windows[i].hypr && windows[i].hypr.urgent === true) return true
      }
      return false
    }
    readonly property bool allMinimized: {
      if (!running) return false
      for (var i = 0; i < windows.length; i++) if (!windows[i].minimized) return false
      return true
    }
    readonly property bool launching: root.isLaunching(key)
    readonly property bool lifted: root.dragIndex === index
    readonly property bool hovered: slotMouse.containsMouse && !root.dragging
    readonly property string labelText: {
      if (root.vertical || !running) return ""
      if (root.labelsMode === "all") {
        if (focusedWindow) return root.windowTitle(focusedWindow) || root.appName(item)
        return windowCount === 1 ? (root.windowTitle(windows[0]) || root.appName(item)) : root.appName(item)
      }
      if (root.labelsMode === "focused" && focused) return root.windowTitle(focusedWindow) || root.appName(item)
      return ""
    }
    readonly property bool showLabel: labelText !== ""
    property real pulse: 1

    z: lifted ? 2 : 0
    width: root.vertical ? root.barSize : implicitWidth
    height: root.vertical ? implicitHeight : root.barSize
    implicitWidth: root.slotPadding * 2 + root.iconSize + (showLabel ? root.labelGap + label.width : 0)
    implicitHeight: root.iconSize + root.slotPadding * 2

    Behavior on implicitWidth {
      enabled: !root.dragging
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
    }

    // While dragged, the button's content follows the pointer; the slot
    // itself stays put so the layout does not shift under the drag.
    Item {
      id: content
      anchors.fill: parent
      opacity: slot.lifted ? 0.85 : 1
      transform: Translate {
        x: slot.lifted && !root.vertical ? root.dragOffset : 0
        y: slot.lifted && root.vertical ? root.dragOffset : 0
      }

      SlotBackground {
        hovered: slot.hovered || (root.previewOpen && root.previewSlot === slot) || root.menuSlot === slot
        pressed: slotMouse.pressed && !slot.lifted
        active: slot.focused || slot.lifted
        urgent: slot.urgent
      }

      Image {
        id: icon
        x: root.vertical ? Math.round((parent.width - width) / 2) : root.slotPadding
        y: root.vertical ? root.slotPadding : Math.round((parent.height - height) / 2)
        width: root.iconSize
        height: root.iconSize
        sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
        source: slot.item ? root.iconFor(slot.item) : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        opacity: slot.launching ? slot.pulse : (slot.running && !slot.allMinimized ? 1 : root.idleOpacity)
        scale: slotMouse.pressed ? 0.86 : 1

        Behavior on scale { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }
      }

      // How many windows the app has, once it has more than one.
      Rectangle {
        visible: slot.windowCount > 1
        readonly property int size: Math.max(9, Math.round(root.iconSize * 0.55))
        width: Math.max(size, countText.implicitWidth + 4)
        height: size
        radius: size / 2
        x: icon.x + icon.width - width * 0.6
        y: Math.max(0, icon.y - height * 0.3)
        color: Commons.Color.accent
        border.width: 1
        border.color: Commons.Color.background

        Text {
          id: countText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: slot.windowCount > 9 ? "9+" : String(slot.windowCount)
          color: Commons.Color.background
          font.family: root.fontFamily
          font.pixelSize: Math.max(7, parent.size - 3)
          font.bold: true
        }
      }

      Text {
        id: label
        visible: slot.showLabel
        x: icon.x + icon.width + root.labelGap
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(root.maxLabelWidth, implicitWidth)
        textFormat: Text.PlainText
        text: slot.labelText
        elide: Text.ElideRight
        maximumLineCount: 1
        color: root.fg
        opacity: slot.focused ? 1 : 0.8
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // Running indicator under the icon (like Windows, on a top or bottom
      // bar alike): a dot for running, a wide accent bar for focused, red
      // for urgent, faint when minimized.
      Rectangle {
        id: indicator
        visible: slot.running || slot.launching
        readonly property int length: slot.focused ? Math.round(root.iconSize * 0.9) : Math.max(4, Math.round(root.iconSize * 0.3))
        readonly property int thickness: 2
        readonly property real iconCenterX: icon.x + icon.width / 2
        readonly property real iconCenterY: icon.y + icon.height / 2
        width: root.vertical ? thickness : length
        height: root.vertical ? length : thickness
        radius: 1
        color: slot.urgent ? Commons.Color.urgent
          : slot.focused ? Commons.Color.accent
          : Util.alpha(root.fg, slot.allMinimized ? 0.35 : 0.75)
        opacity: slot.launching && !slot.running ? slot.pulse : 1
        x: root.vertical
          ? (root.barPosition === "right" ? Style.space(1) : parent.width - width - Style.space(1))
          : Math.round(iconCenterX - width / 2)
        y: root.vertical
          ? Math.round(iconCenterY - height / 2)
          : parent.height - height - Style.space(1)

        Behavior on width { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: Style.duration(150) } }
      }
    }

    SequentialAnimation {
      running: slot.launching && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) slot.pulse = 1

      NumberAnimation { target: slot; property: "pulse"; from: 1; to: 0.35; duration: Style.duration(500); easing.type: Easing.InOutSine }
      NumberAnimation { target: slot; property: "pulse"; to: 1; duration: Style.duration(500); easing.type: Easing.InOutSine }
    }

    MouseArea {
      id: slotMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      // Once a drag starts, keep it even if the pointer leaves the strip.
      preventStealing: true

      readonly property int dragButtons: Qt.LeftButton | Qt.RightButton
      property real wheelAccumulator: 0
      property point pressPoint
      property bool dragged: false

      // In the strip's coordinates, which stay still while the button's
      // content moves, so each move is not fed back into the next.
      function stripPoint(event) {
        return slotMouse.mapToItem(strip, event.x, event.y)
      }

      onPressed: function(event) {
        if (root.bar) root.bar.hideTooltip(slot)
        root.closePreview()
        slotMouse.dragged = false
        if (event.button & slotMouse.dragButtons) slotMouse.pressPoint = slotMouse.stripPoint(event)
      }

      // A left- or right-button drag reorders.
      onPositionChanged: function(event) {
        if (!(slotMouse.pressedButtons & slotMouse.dragButtons)) return
        var point = slotMouse.stripPoint(event)
        var delta = root.vertical ? point.y - slotMouse.pressPoint.y : point.x - slotMouse.pressPoint.x
        if (!root.dragging) {
          if (Math.abs(delta) < Style.space(6)) return
          slotMouse.dragged = true
          root.startDrag(slot.index)
        }
        if (!slot.lifted) return
        root.dragOffset = delta
        root.dropIndex = Model.dropIndex(root.slotCenters(), slot.index, root.vertical ? point.y : point.x)
      }

      onReleased: function(event) {
        if (!slot.lifted) return
        var from = root.dragIndex
        var to = root.dropIndex
        var key = slot.key
        root.endDrag()
        if (to !== from) root.placeAt(key, to, false)
      }

      onCanceled: if (slot.lifted) root.endDrag()

      onClicked: function(event) {
        if (root.bar) root.bar.hideTooltip(slot)
        root.closePreview()
        // A drag ends in a release over the app, which is not a click on it.
        if (slotMouse.dragged) {
          slotMouse.dragged = false
          return
        }
        if (event.button === Qt.RightButton) {
          if (root.menuSlot === slot) root.closeMenu()
          else root.openMenu(slot)
          return
        }
        root.closeMenu()
        if (event.button === Qt.MiddleButton || (event.modifiers & Qt.ShiftModifier)) root.launch(slot.item)
        else root.activate(slot.item)
      }

      onWheel: function(wheel) {
        var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
        slotMouse.wheelAccumulator += delta
        while (Math.abs(slotMouse.wheelAccumulator) >= 120) {
          var step = slotMouse.wheelAccumulator > 0 ? -1 : 1
          slotMouse.wheelAccumulator -= step * -120
          root.cycle(slot.item, step)
        }
      }

      onEntered: root.hoverSlot(slot)
      onExited: {
        slotMouse.wheelAccumulator = 0
        root.unhoverSlot(slot)
      }
    }
  }

  // ------------------------------------------------------------- previews

  readonly property int previewTileWidth: Style.space(220)

  PopupCard {
    id: previewCard

    readonly property var windows: root.previewSlot && root.previewSlot.item ? root.previewSlot.item.windows : []
    readonly property int tileWidth: {
      var count = Math.max(1, windows.length)
      var room = previewCard.availableCardWidth > 0 ? previewCard.availableCardWidth - previewCard.padding * 2 : root.previewTileWidth * count
      var fit = Math.floor((room - Style.space(8) * (count - 1)) / count)
      return Math.max(Style.space(120), Math.min(root.previewTileWidth, fit))
    }

    anchorItem: root.previewSlot || root
    owner: previewOwner
    bar: root.bar
    triggerMode: "hover"
    open: root.previewOpen && !!root.previewSlot && windows.length > 0
    padding: Style.space(8)
    contentWidth: previewCard.fittedContentWidth(previewRow.implicitWidth + padding * 2)
    contentHeight: previewCard.fittedContentHeight(previewRow.implicitHeight)

    onContainsMouseChanged: {
      if (containsMouse) previewCloseTimer.stop()
      else if (root.previewOpen) previewCloseTimer.restart()
    }

    Row {
      id: previewRow
      spacing: Style.space(8)

      Repeater {
        model: previewCard.windows
        delegate: PreviewTile {}
      }
    }
  }

  component PreviewTile: Rectangle {
    id: tile

    required property var modelData
    readonly property var win: modelData
    readonly property bool active: !!win.toplevel && win.toplevel.activated

    width: previewCard.tileWidth
    height: tileColumn.implicitHeight + Style.space(12)
    radius: Math.max(3, Style.cornerRadius)
    color: tileMouse.containsMouse ? Util.alpha(Commons.Color.popups.text, 0.1)
      : active ? Util.alpha(Commons.Color.popups.text, 0.06)
      : "transparent"
    border.width: active ? 1 : 0
    border.color: Util.alpha(Commons.Color.accent, 0.7)

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onClicked: function(event) {
        if (event.button === Qt.MiddleButton) {
          root.closeWindow(tile.win)
          return
        }
        root.closePreview()
        root.focusWindow(tile.win)
      }
    }

    Column {
      id: tileColumn
      x: Style.space(6)
      y: Style.space(6)
      width: tile.width - Style.space(12)
      spacing: Style.space(6)

      Item {
        width: parent.width
        height: Math.max(titleText.implicitHeight, Style.space(18))

        Image {
          id: tileIcon
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14)
          height: Style.space(14)
          sourceSize: Qt.size(width * 2, height * 2)
          source: root.previewSlot && root.previewSlot.item ? root.iconFor(root.previewSlot.item) : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
        }

        Text {
          id: titleText
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: tileIcon.right
          anchors.leftMargin: Style.space(6)
          anchors.right: closeButton.left
          anchors.rightMargin: Style.space(4)
          textFormat: Text.PlainText
          text: root.windowTitle(tile.win) || root.appName(root.previewSlot ? root.previewSlot.item : null)
          elide: Text.ElideRight
          maximumLineCount: 1
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Rectangle {
          id: closeButton
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          width: Style.space(18)
          height: Style.space(18)
          radius: Math.max(2, Style.cornerRadius)
          opacity: tileMouse.containsMouse || closeMouse.containsMouse ? 1 : 0
          color: closeMouse.containsMouse ? Commons.Color.urgent : "transparent"

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "✕"
            color: closeMouse.containsMouse ? Commons.Color.background : Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeWindow(tile.win)
          }
        }
      }

      Item {
        id: thumbBox
        width: parent.width
        height: Math.round(width * 10 / 16)

        ScreencopyView {
          id: shot
          readonly property real aspect: sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16 / 10
          anchors.centerIn: parent
          width: Math.min(thumbBox.width, thumbBox.height * aspect)
          height: width / aspect
          captureSource: previewCard.open ? tile.win.toplevel : null
          live: previewCard.open
          constraintSize: Qt.size(Math.round(thumbBox.width * 1.5), Math.round(thumbBox.height * 1.5))
        }

        // Nothing captured yet (or a minimized window Hyprland is not
        // drawing): show the app icon instead.
        Image {
          visible: !shot.hasContent
          anchors.centerIn: parent
          width: Math.round(thumbBox.height * 0.45)
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
          source: tileIcon.source
          fillMode: Image.PreserveAspectFit
          opacity: 0.6
          asynchronous: true
        }

        Rectangle {
          readonly property string badge: tile.win.minimized ? strings.t("preview.minimized")
            : tile.win.workspaceId >= 1 && tile.win.workspaceId !== root.focusedWorkspaceId
              ? strings.t("preview.workspace").arg(Commons.I18n.formatNumber(tile.win.workspaceId))
              : ""
          visible: badge !== ""
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(4)
          width: badgeText.implicitWidth + Style.space(10)
          height: badgeText.implicitHeight + Style.space(4)
          radius: Math.max(2, Style.cornerRadius)
          color: Util.alpha(Commons.Color.popups.background, 0.85)

          Text {
            id: badgeText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: parent.badge
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- menus

  readonly property var menuItem: root.menuSlot ? root.menuSlot.item : null
  readonly property var menuWindows: root.menuItem ? root.menuItem.windows : []
  readonly property bool menuHasEntry: !!root.entryFor(root.menuItem)
  readonly property int menuIndex: root.menuItem ? root.shownKeys().indexOf(root.menuItem.key) : -1
  readonly property bool menuAnyElsewhere: {
    for (var i = 0; i < root.menuWindows.length; i++) {
      if (root.menuWindows[i].minimized || root.menuWindows[i].workspaceId !== root.focusedWorkspaceId) return true
    }
    return false
  }
  readonly property bool menuAllMinimized: {
    if (root.menuWindows.length === 0) return false
    for (var i = 0; i < root.menuWindows.length; i++) if (!root.menuWindows[i].minimized) return false
    return true
  }

  PopupCard {
    id: menuCard
    anchorItem: root.menuAnchor || root
    owner: menuOwner
    bar: root.bar
    open: root.menuOpen
    padding: Style.space(6)
    contentWidth: menuCard.fittedContentWidth(Style.space(260))
    contentHeight: menuCard.fittedContentHeight(menuColumn.implicitHeight, Style.space(560))

    Column {
      id: menuColumn
      width: parent.width

      // ---- app jump list

      MenuHeader {
        visible: !!root.menuItem
        text: root.appName(root.menuItem)
        subtext: root.menuWindows.length > 0 ? strings.tn("menu.windowCount", root.menuWindows.length).arg(Commons.I18n.formatNumber(root.menuWindows.length)) : strings.t("menu.notRunning")
        iconSource: root.menuItem ? root.iconFor(root.menuItem) : ""
      }

      Repeater {
        model: root.menuItem && root.menuWindows.length > 1 ? root.menuWindows : []
        delegate: MenuRow {
          required property var modelData
          text: root.windowTitle(modelData) || root.appName(root.menuItem)
          hint: modelData.minimized ? strings.t("preview.minimized")
            : modelData.workspaceId >= 1 ? strings.t("preview.workspace").arg(Commons.I18n.formatNumber(modelData.workspaceId)) : ""
          checked: !!modelData.toplevel && modelData.toplevel.activated
          onTriggered: root.focusWindow(modelData)
        }
      }

      MenuSeparator { visible: !!root.menuItem && root.menuWindows.length > 1 }

      MenuRow {
        visible: !!root.menuItem && root.menuHasEntry
        text: root.menuWindows.length > 0 ? strings.t("menu.newWindow") : strings.t("menu.open")
        hint: root.menuWindows.length > 0 ? strings.t("menu.middleClick") : ""
        onTriggered: root.launch(root.menuItem)
      }

      MenuRow {
        visible: !!root.menuItem && root.menuHasEntry
        text: root.menuItem && root.isPinned(root.menuItem.key) ? strings.t("menu.unpin") : strings.t("menu.pin")
        onTriggered: root.setPinned(root.menuItem.key, !root.isPinned(root.menuItem.key))
      }

      MenuRow {
        visible: !!root.menuItem && root.menuIndex > 0
        text: root.vertical ? strings.t("menu.moveUp") : strings.t("menu.moveLeft")
        onTriggered: root.moveBy(root.menuItem.key, -1)
      }

      MenuRow {
        visible: !!root.menuItem && root.menuIndex >= 0 && root.menuIndex < itemModel.count - 1
        text: root.vertical ? strings.t("menu.moveDown") : strings.t("menu.moveRight")
        onTriggered: root.moveBy(root.menuItem.key, 1)
      }

      MenuRow {
        visible: !!root.menuItem && root.menuAnyElsewhere && root.focusedWorkspaceId >= 1
        text: strings.t("menu.moveHere")
        onTriggered: {
          var list = root.menuWindows.slice()
          for (var i = 0; i < list.length; i++) root.moveWindowHere(list[i])
        }
      }

      MenuRow {
        visible: !!root.menuItem && root.menuWindows.length > 0
        text: root.menuAllMinimized ? strings.t("menu.restore") : strings.t("menu.minimize")
        onTriggered: {
          var list = root.menuWindows.slice()
          if (root.menuAllMinimized) {
            for (var i = 0; i < list.length; i++) root.focusWindow(list[i])
          } else {
            for (var j = 0; j < list.length; j++) root.minimizeWindow(list[j])
          }
        }
      }

      MenuSeparator { visible: !!root.menuItem && root.menuWindows.length > 0 }

      MenuRow {
        visible: !!root.menuItem && root.menuWindows.length > 0
        danger: true
        text: root.menuWindows.length > 1
          ? strings.tn("menu.closeAll", root.menuWindows.length).arg(Commons.I18n.formatNumber(root.menuWindows.length))
          : strings.t("menu.close")
        onTriggered: {
          var list = root.menuWindows.slice()
          for (var i = 0; i < list.length; i++) root.closeWindow(list[i])
        }
      }

      // ---- taskbar settings (right-click the apps button)

      MenuHeader {
        visible: root.settingsMenuOpen
        text: strings.t("settings.title")
        subtext: strings.t("settings.hint")
      }

      MenuLabel { visible: root.settingsMenuOpen; text: strings.t("settings.labels") }

      Repeater {
        model: root.settingsMenuOpen ? [["none", "settings.labelsNone"], ["focused", "settings.labelsFocused"], ["all", "settings.labelsAll"]] : []
        delegate: MenuRow {
          required property var modelData
          text: strings.t(modelData[1])
          checked: root.labelsMode === modelData[0]
          keepOpen: true
          onTriggered: root.saveSettings({ labels: modelData[0] })
        }
      }

      MenuLabel { visible: root.settingsMenuOpen; text: strings.t("settings.filter") }

      Repeater {
        model: root.settingsMenuOpen ? [["all", "settings.filterAll"], ["monitor", "settings.filterMonitor"], ["workspace", "settings.filterWorkspace"]] : []
        delegate: MenuRow {
          required property var modelData
          text: strings.t(modelData[1])
          checked: root.filterMode === modelData[0]
          keepOpen: true
          onTriggered: root.saveSettings({ filter: modelData[0] })
        }
      }

      MenuSeparator { visible: root.settingsMenuOpen }

      MenuRow {
        visible: root.settingsMenuOpen
        text: strings.t("settings.previews")
        checked: root.previewsEnabled
        keepOpen: true
        onTriggered: root.saveSettings({ previews: !root.previewsEnabled })
      }

      MenuRow {
        visible: root.settingsMenuOpen
        text: strings.t("settings.clickToMinimize")
        checked: root.clickToMinimize
        keepOpen: true
        onTriggered: root.saveSettings({ clickToMinimize: !root.clickToMinimize })
      }

      MenuSeparator { visible: root.settingsMenuOpen }

      MenuRow {
        visible: root.settingsMenuOpen
        text: strings.t("settings.applyLayout")
        hint: strings.t("settings.applyLayoutHint")
        onTriggered: root.applyLayout(true)
      }

      MenuRow {
        visible: root.settingsMenuOpen
        text: strings.t("settings.pinFocused")
        onTriggered: {
          var toplevel = ToplevelManager.activeToplevel
          var entry = toplevel ? root.entryForAppId(toplevel.appId) : null
          if (entry) root.setPinned(entry.id, true)
        }
      }

      MenuRow {
        visible: root.settingsMenuOpen
        text: strings.t("settings.hideAppsButton")
        onTriggered: root.saveSettings({ showAppsButton: false })
      }
    }
  }

  component MenuHeader: Item {
    id: header
    property string text: ""
    property string subtext: ""
    property string iconSource: ""

    width: parent ? parent.width : 0
    height: visible ? headerColumn.implicitHeight + Style.space(10) : 0

    Image {
      id: headerIcon
      visible: header.iconSource !== ""
      anchors.verticalCenter: parent.verticalCenter
      x: Style.spacing.controlPaddingX
      width: visible ? Style.space(24) : 0
      height: Style.space(24)
      sourceSize: Qt.size(width * 2, height * 2)
      source: header.iconSource
      fillMode: Image.PreserveAspectFit
      asynchronous: true
    }

    Column {
      id: headerColumn
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: headerIcon.visible ? headerIcon.right : parent.left
      anchors.leftMargin: headerIcon.visible ? Style.space(8) : Style.spacing.controlPaddingX
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: header.text
        elide: Text.ElideRight
        color: Commons.Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        visible: header.subtext !== ""
        textFormat: Text.PlainText
        text: header.subtext
        elide: Text.ElideRight
        color: Util.alpha(Commons.Color.popups.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  component MenuLabel: Text {
    width: parent ? parent.width : 0
    height: visible ? implicitHeight + Style.space(8) : 0
    leftPadding: Style.spacing.controlPaddingX
    topPadding: Style.space(6)
    verticalAlignment: Text.AlignBottom
    textFormat: Text.PlainText
    color: Util.alpha(Commons.Color.popups.text, 0.55)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  component MenuSeparator: Item {
    width: parent ? parent.width : 0
    height: visible ? Style.space(9) : 0

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(6)
      width: parent.width - Style.space(12)
      height: 1
      color: Util.alpha(Commons.Color.popups.text, 0.15)
    }
  }

  component MenuRow: Rectangle {
    id: row

    property string text: ""
    property string hint: ""
    property bool checked: false
    property bool danger: false
    property bool keepOpen: false
    signal triggered()

    width: parent ? parent.width : 0
    height: visible ? Style.spacing.popupRowHeight : 0
    radius: Math.max(2, Style.cornerRadius)
    color: rowMouse.containsMouse
      ? (row.danger ? Util.alpha(Commons.Color.urgent, 0.25) : Style.hoverFill)
      : "transparent"

    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.right: hintText.visible ? hintText.left : checkText.left
      anchors.rightMargin: Style.space(8)
      textFormat: Text.PlainText
      text: row.text
      elide: Text.ElideRight
      color: row.danger && rowMouse.containsMouse ? Commons.Color.urgent : Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      id: hintText
      visible: row.hint !== ""
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: checkText.left
      anchors.rightMargin: Style.space(4)
      textFormat: Text.PlainText
      text: row.hint
      color: Util.alpha(Commons.Color.popups.text, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      id: checkText
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      width: row.checked ? implicitWidth : 0
      textFormat: Text.PlainText
      text: row.checked ? "✓" : ""
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        row.triggered()
        if (!row.keepOpen) root.closeMenu()
      }
    }
  }
}

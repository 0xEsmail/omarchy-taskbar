// Run with: node tests/model.test.js
const assert = require("assert")
const M = require("../TaskbarModel.js")

let passed = 0
function test(name, fn) { fn(); passed++; }

test("pinnedIds strips .desktop and dupes", () => {
  assert.deepStrictEqual(M.pinnedIds(["foot.desktop", "foot", " chromium ", "", null]), ["foot", "chromium"])
  assert.deepStrictEqual(M.pinnedIds(undefined), [])
})

test("buildItems puts pins first, then running apps", () => {
  const windows = [
    { key: "code", workspaceId: 2 },
    { key: "foot", workspaceId: 1 },
    { key: "code", workspaceId: 3 },
    { key: "scratch", workspaceId: -98 },
    { key: "min", workspaceId: -99, minimized: true },
  ]
  const items = M.buildItems(["foot", "nautilus"], windows, "all", "", 1)
  assert.deepStrictEqual(items.map(i => i.key), ["foot", "nautilus", "code", "min"])
  assert.strictEqual(items[2].windows.length, 2)
  assert.strictEqual(items[1].windows.length, 0)
})

test("filters by workspace and monitor", () => {
  const windows = [
    { key: "a", workspaceId: 1, monitorName: "DP-1" },
    { key: "b", workspaceId: 2, monitorName: "HDMI-A-1" },
  ]
  assert.deepStrictEqual(M.buildItems([], windows, "workspace", "DP-1", 1).map(i => i.key), ["a"])
  assert.deepStrictEqual(M.buildItems([], windows, "monitor", "HDMI-A-1", 2).map(i => i.key), ["b"])
})

test("orderItems keeps session order, newcomers at end", () => {
  const items = [{ key: "a" }, { key: "b" }, { key: "c" }]
  assert.deepStrictEqual(M.orderItems(items, ["c", "a", "gone"]).map(i => i.key), ["c", "a", "b"])
})

test("pinsInOrder keeps hidden pins", () => {
  const pins = M.pinsInOrder(["b", "x", "a"], { a: true, b: true, z: true }, ["a", "z", "b"])
  assert.deepStrictEqual(pins, ["b", "a", "z"])
})

test("clickAction: launch, minimize, focus, cycle", () => {
  assert.strictEqual(M.clickAction([], 1, true).action, "launch")
  assert.deepStrictEqual(M.clickAction([{ workspaceId: 1, activated: true }], 1, true), { action: "minimize", index: 0 })
  assert.deepStrictEqual(M.clickAction([{ workspaceId: 1, activated: true }], 1, false), { action: "focus", index: 0 })
  assert.deepStrictEqual(M.clickAction([{ workspaceId: 1, activated: false }], 1, true), { action: "focus", index: 0 })
  // Two windows, first focused -> cycle to second.
  assert.deepStrictEqual(M.clickAction([{ workspaceId: 1, activated: true }, { workspaceId: 1 }], 1, true), { action: "focus", index: 1 })
  // Prefers window on current workspace over elsewhere.
  assert.deepStrictEqual(M.clickAction([{ workspaceId: 4 }, { workspaceId: 1 }], 1, true), { action: "focus", index: 1 })
  // Minimized window is restored, not minimized again.
  assert.deepStrictEqual(M.clickAction([{ workspaceId: -99, minimized: true, activated: true }], 1, true).action, "focus")
})

test("stepWindow wraps", () => {
  const w = [{}, { activated: true }, {}]
  assert.strictEqual(M.stepWindow(w, 1), 2)
  assert.strictEqual(M.stepWindow(w, -1), 0)
  assert.strictEqual(M.stepWindow([{}, {}, { activated: true }], 1), 0)
  assert.strictEqual(M.stepWindow([{}, {}], -1), 1)
})

test("dropIndex: where a dragged button lands", () => {
  const centers = [10, 30, 50, 70]
  assert.strictEqual(M.dropIndex(centers, 0, 5), 0)    // still before its own center
  assert.strictEqual(M.dropIndex(centers, 0, 40), 1)   // past the next center
  assert.strictEqual(M.dropIndex(centers, 0, 100), 3)  // past the end
  assert.strictEqual(M.dropIndex(centers, 3, 0), 0)    // to the front
  assert.strictEqual(M.dropIndex(centers, 2, 45), 2)   // not yet past a neighbour
  assert.strictEqual(M.dropIndex(centers, 2, 25), 1)   // past the left neighbour
  assert.strictEqual(M.dropIndex([], 0, 5), 0)
})

test("orderWithKeyAt moves a key", () => {
  assert.deepStrictEqual(M.orderWithKeyAt(["a", "b", "c"], "a", 2), ["b", "c", "a"])
  assert.deepStrictEqual(M.orderWithKeyAt(["a", "b", "c"], "c", 0), ["c", "a", "b"])
  assert.deepStrictEqual(M.orderWithKeyAt(["a", "b", "c"], "b", 99), ["a", "c", "b"])
})

test("claimingEntryId", () => {
  const entries = [
    { id: "btop", command: ["/usr/bin/btop"], runInTerminal: true },
    { id: "lazy", execString: "foot --app-id=org.x.lazy lazygit" },
  ]
  assert.strictEqual(M.claimingEntryId("org.omarchy.btop", entries), "btop")
  assert.strictEqual(M.claimingEntryId("org.x.lazy", entries), "lazy")
  assert.strictEqual(M.claimingEntryId("firefox", entries), "")
})

test("hyprAddress", () => {
  assert.strictEqual(M.hyprAddress("abc"), "0xabc")
  assert.strictEqual(M.hyprAddress("0xabc"), "0xabc")
  assert.strictEqual(M.hyprAddress(""), "")
})

console.log(`ok - ${passed} tests passed`)

// Run with: node tests/layout.test.js
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Layout.js is a QML `.pragma library` file; drop that directive and load it as CommonJS.
const source = fs.readFileSync(path.join(__dirname, "..", "Layout.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const mod = { exports: {} }
new Function("module", source)(mod)
const L = mod.exports

const config = {
  bar: {
    layout: {
      left: [{ id: "a.menu" }, { id: "a.workspaces" }],
      center: [{ id: "a.clock" }, { id: "x.radar" }],
      right: [{ id: "a.tray" }]
    }
  }
}
const plugins = [
  { id: "a.menu", name: "Menu", kinds: ["bar-widget"], firstParty: true, canDisable: true },
  { id: "a.workspaces", name: "Workspaces", kinds: ["bar-widget"], firstParty: true, canDisable: true },
  { id: "a.clock", name: "Clock", kinds: ["bar-widget"], firstParty: true, canDisable: true },
  { id: "x.radar", name: "Radar", kinds: ["bar-widget", "panel"], firstParty: false, canDisable: true },
  { id: "a.tray", name: "Tray", kinds: ["bar-widget"], firstParty: true, canDisable: true },
  { id: "a.battery", name: "Battery", kinds: ["service"], firstParty: true, canDisable: true },
  { id: "a.spare", name: "Spare", kinds: ["bar-widget"], firstParty: true, canDisable: true },
  { id: "x.deck", name: "Omaseiton", kinds: ["bar-widget"], firstParty: false, canDisable: true }
]

// buildRows: headers, order, available, names, self protection
{
  const rows = L.buildRows(config, plugins, "x.deck", false)
  assert.deepEqual(rows.filter(r => r.type === "header").map(r => r.label), ["Left", "Center", "Right", "Available", "Layouts"])
  assert.deepEqual(rows.filter(r => r.type === "widget" && r.section === "center").map(r => r.name), ["Clock", "Radar"])
  const avail = rows.filter(r => r.type === "available").map(r => r.id)
  assert.deepEqual(avail, ["a.spare", "x.deck"], "services and placed widgets are not listed as available")
  assert.equal(rows.find(r => r.id === "x.radar").firstParty, false)
  assert.equal(L.buildRows(config, plugins, "a.clock", false).find(r => r.id === "a.clock").canDisable, false)
  assert.deepEqual(L.buildRows(config, plugins, "", true).filter(r => r.type === "header").map(r => r.label),
    ["Start", "Center", "End", "Available", "Layouts"])
}

// buildRows: unknown ids fall back to the id, empty config is safe
{
  const rows = L.buildRows({ bar: { layout: { left: [{ id: "ghost.widget" }] } } }, [], "", false)
  assert.equal(rows.find(r => r.type === "widget").name, "ghost.widget")
  assert.equal(L.buildRows(null, null, "", false).filter(r => r.type === "header").length, 5)
}

// computeMove
assert.deepEqual(L.computeMove(config, "center", 1, "up"),
  { fromSection: "center", fromIndex: 1, section: "center", index: 0 })
assert.equal(L.computeMove(config, "center", 0, "up"), null)
assert.deepEqual(L.computeMove(config, "left", 0, "down"),
  { fromSection: "left", fromIndex: 0, section: "left", index: 1 })
assert.equal(L.computeMove(config, "left", 1, "down"), null)
assert.deepEqual(L.computeMove(config, "left", 1, "next"),
  { fromSection: "left", fromIndex: 1, section: "center", index: 0 })
assert.deepEqual(L.computeMove(config, "right", 0, "prev"),
  { fromSection: "right", fromIndex: 0, section: "center", index: 2 })
assert.equal(L.computeMove(config, "left", 0, "prev"), null)
assert.equal(L.computeMove(config, "right", 0, "next"), null)
assert.equal(L.computeMove(config, "center", 9, "up"), null)
assert.equal(L.computeMove(config, "nope", 0, "up"), null)
assert.equal(L.computeMove(config, "center", 0, "sideways"), null)

// to-<lane>: jump straight to a lane
assert.deepEqual(L.computeMove(config, "left", 0, "to-right"),
  { fromSection: "left", fromIndex: 0, section: "right", index: 1 })
assert.deepEqual(L.computeMove(config, "right", 0, "to-left"),
  { fromSection: "right", fromIndex: 0, section: "left", index: 2 })
assert.equal(L.computeMove(config, "left", 0, "to-left"), null, "already in that lane")
assert.equal(L.computeMove(config, "left", 0, "to-nowhere"), null)

// collapsed lanes hide their widgets but keep the header and count
{
  const rows = L.buildRows(config, plugins, "x.deck", false, { center: true })
  const header = rows.find(r => r.type === "header" && r.section === "center")
  assert.equal(header.collapsed, true)
  assert.equal(header.count, 2)
  assert.equal(rows.filter(r => r.type === "widget" && r.section === "center").length, 0)
  assert.equal(rows.filter(r => r.type === "widget" && r.section === "left").length, 2)
  assert.equal(rows.filter(r => r.type === "available").length, 2, "collapsing a lane does not make its widgets available")
  const closed = L.buildRows(config, plugins, "x.deck", false, { available: true })
  assert.equal(closed.filter(r => r.type === "available").length, 0)
  assert.equal(closed.find(r => r.section === "available").count, 2)
}

// findRow / stepCursor
{
  const rows = L.buildRows(config, plugins, "x.deck", false)
  const at = L.findRow(rows, { section: "center", index: 1 })
  assert.equal(rows[at].id, "x.radar")
  assert.equal(L.findRow(rows, { id: "a.spare" }) > at, true)
  assert.equal(L.findRow(rows, { id: "x.radar" }), at, "a widget is found by id too")
  assert.equal(L.findRow(rows, null), -1)
  assert.equal(L.stepCursor(rows, -1, 1), 0, "the first stop is the first header")
  assert.equal(rows[L.stepCursor(rows, -1, 1)].type, "header")
  assert.equal(L.stepCursor(rows, 0, -1), 0, "cannot step above the first row")
  const last = rows.length - 1
  assert.equal(L.stepCursor(rows, last, 1), last)
  assert.equal(L.stepCursor(rows, 3, 1), 4)
}

// Layouts node: stock + mine + automatic snapshots
{
  const none = L.buildLayoutRows([], {})
  assert.deepEqual(none.map(r => r.type + ":" + (r.slot || r.section)),
    ["header:layouts", "layout:omarchy-default", "layout:mine"])
  assert.equal(none[2].exists, false)
  assert.equal(none[2].note, "not saved yet")
  const some = L.buildLayoutRows([
    { slot: "auto-20260101-000002", savedAt: "b", widgets: 3 },
    { slot: "mine", savedAt: "a", widgets: 20 },
    { slot: "auto-20260101-000001", savedAt: "c", widgets: 4 },
    { slot: "stray", savedAt: "d", widgets: 1 }
  ], {})
  assert.deepEqual(some.map(r => r.slot || r.section),
    ["layouts", "omarchy-default", "mine", "auto-20260101-000002", "auto-20260101-000001"],
    "unknown slots are ignored, input order of autos is kept")
  assert.equal(some[0].count, 4)
  assert.equal(some[2].exists, true)
  assert.equal(some[2].widgets, 20)
  assert.equal(L.buildLayoutRows(some, { layouts: true }).length, 1, "folded: header only")
  const all = L.buildRows(config, plugins, "x.deck", false, {}, [{ slot: "mine", savedAt: "a", widgets: 5 }])
  assert.equal(all[all.length - 3].type, "header", "layouts come after the available list")
  assert.equal(all[all.length - 1].type, "layout")
  assert.equal(L.buildLayoutRows(null, null).length, 3, "bad input is safe")
}

assert.deepEqual(L.parseJson("{bad", []), [])
assert.deepEqual(L.parseJson("", {}), {})
console.log("layout tests passed")

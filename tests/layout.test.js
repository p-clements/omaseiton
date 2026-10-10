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
  assert.deepEqual(rows.filter(r => r.type === "header").map(r => r.label), ["Left", "Center", "Right", "Available"])
  assert.deepEqual(rows.filter(r => r.type === "widget" && r.section === "center").map(r => r.name), ["Clock", "Radar"])
  const avail = rows.filter(r => r.type === "available").map(r => r.id)
  assert.deepEqual(avail, ["a.spare", "x.deck"], "services and placed widgets are not listed as available")
  assert.equal(rows.find(r => r.id === "x.radar").firstParty, false)
  assert.equal(L.buildRows(config, plugins, "a.clock", false).find(r => r.id === "a.clock").canDisable, false)
  assert.deepEqual(L.buildRows(config, plugins, "", true).filter(r => r.type === "header").map(r => r.label),
    ["Start", "Center", "End", "Available"])
}

// buildRows: unknown ids fall back to the id, empty config is safe
{
  const rows = L.buildRows({ bar: { layout: { left: [{ id: "ghost.widget" }] } } }, [], "", false)
  assert.equal(rows.find(r => r.type === "widget").name, "ghost.widget")
  assert.equal(L.buildRows(null, null, "", false).filter(r => r.type === "header").length, 4)
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

// findRow / stepCursor
{
  const rows = L.buildRows(config, plugins, "x.deck", false)
  const at = L.findRow(rows, { section: "center", index: 1 })
  assert.equal(rows[at].id, "x.radar")
  assert.equal(L.findRow(rows, { id: "a.spare" }) > at, true)
  assert.equal(L.findRow(rows, null), -1)
  const first = L.stepCursor(rows, -1, 1)
  assert.equal(rows[first].type, "widget")
  assert.equal(L.stepCursor(rows, first, -1), first, "cannot step above the first row")
  const last = rows.length - 1
  assert.equal(L.stepCursor(rows, last, 1), last)
  const afterLastBar = L.findRow(rows, { section: "right", index: 0 })
  assert.equal(rows[L.stepCursor(rows, afterLastBar, 1)].type, "available", "skips headers")
}

assert.deepEqual(L.parseJson("{bad", []), [])
assert.deepEqual(L.parseJson("", {}), {})
console.log("layout tests passed")

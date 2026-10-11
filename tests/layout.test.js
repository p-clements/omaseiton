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

// findRow: precise target first, then header, then id
{
  const rows = L.buildRows({ bar: { layout: { left: [{ id: "a.spacer" }, { id: "a.spacer" }, { id: "a.menu" }], center: [], right: [] } } }, plugins, "x.deck", false)
  const second = L.findRow(rows, { id: "a.spacer", section: "left", index: 1 })
  assert.equal(rows[second].index, 1, "with two spacers, section and index win over id")
  assert.equal(rows[L.findRow(rows, { id: "a.spacer" })].index, 0, "by id alone, the first one")
  assert.equal(rows[L.findRow(rows, { header: "center" })].type, "header")
  assert.equal(L.findRow(rows, { section: "left", index: 99 }), -1)
  assert.equal(L.findRow(rows, {}), -1)
}

// resolveKey
{
  const widget = { type: "widget", id: "a.clock", section: "center", index: 1 }
  const header = { type: "header", section: "center", collapsed: false }
  const avail = { type: "available", id: "a.spare" }
  const mine = { type: "layout", kind: "mine", slot: "mine", exists: true }
  const stock = { type: "layout", kind: "default", slot: "omarchy-default", exists: true }
  const k = (row, token, ctx) => L.resolveKey(row, token, ctx)

  // navigation works on every row, and with no row at all
  for (const row of [widget, header, avail, mine, null]) {
    assert.deepEqual(k(row, "down"), { kind: "cursor", dy: 1 })
    assert.deepEqual(k(row, "j"), { kind: "cursor", dy: 1 })
    assert.deepEqual(k(row, "up"), { kind: "cursor", dy: -1 })
    assert.deepEqual(k(row, "k"), { kind: "cursor", dy: -1 })
    assert.deepEqual(k(row, "home"), { kind: "cursor", to: "first" })
    assert.deepEqual(k(row, "g"), { kind: "cursor", to: "first" })
    assert.deepEqual(k(row, "end"), { kind: "cursor", to: "last" })
    assert.deepEqual(k(row, "G"), { kind: "cursor", to: "last" })
    assert.deepEqual(k(row, "]"), { kind: "lane", dir: 1 })
    assert.deepEqual(k(row, "["), { kind: "lane", dir: -1 })
  }

  // Shift moves a widget: up / down is the order, left / right is the lane
  assert.deepEqual(k(widget, "shift+up"), { kind: "move", action: "up" })
  assert.deepEqual(k(widget, "K"), { kind: "move", action: "up" })
  assert.deepEqual(k(widget, "shift+down"), { kind: "move", action: "down" })
  assert.deepEqual(k(widget, "J"), { kind: "move", action: "down" })
  assert.deepEqual(k(widget, "shift+left"), { kind: "move", action: "prev" })
  assert.deepEqual(k(widget, "H"), { kind: "move", action: "prev" })
  assert.deepEqual(k(widget, "shift+right"), { kind: "move", action: "next" })
  assert.deepEqual(k(widget, "L"), { kind: "move", action: "next" })
  for (const row of [header, avail, mine, stock, null]) {
    for (const t of ["shift+up", "shift+down", "shift+left", "shift+right", "K", "J", "H", "L"]) {
      assert.equal(k(row, t).kind, "none", t + " only moves widgets")
    }
  }

  // lanes by number
  assert.deepEqual(k(widget, "1"), { kind: "send", lane: 0 })
  assert.deepEqual(k(widget, "3"), { kind: "send", lane: 2 })
  assert.deepEqual(k(avail, "2"), { kind: "send", lane: 1 })
  assert.equal(k(header, "1").kind, "none")
  assert.equal(k(mine, "2").kind, "none")

  // plain left / right never move a widget; they climb to the lane or fold it
  assert.deepEqual(k(widget, "left"), { kind: "parent" })
  assert.deepEqual(k(widget, "h"), { kind: "parent" })
  assert.deepEqual(k(avail, "left"), { kind: "parent" })
  assert.equal(k(widget, "right").kind, "none")
  assert.equal(k(widget, "l").kind, "none", "l is navigation now, not a reorder")
  assert.deepEqual(k(header, "left"), { kind: "fold", value: true })
  assert.deepEqual(k(header, "right"), { kind: "unfold" })
  assert.deepEqual(k(header, "l"), { kind: "unfold" })

  // toggle and activate
  assert.deepEqual(k(widget, "space"), { kind: "toggle" })
  assert.deepEqual(k(widget, "x"), { kind: "toggle" })
  assert.equal(k(widget, "enter").kind, "none", "Enter never switches a widget off")
  assert.deepEqual(k(avail, "space"), { kind: "toggle" })
  assert.deepEqual(k(avail, "enter"), { kind: "toggle" })
  assert.deepEqual(k(header, "enter"), { kind: "foldToggle" })
  assert.deepEqual(k(header, "space"), { kind: "foldToggle" })

  // layouts
  assert.deepEqual(k(mine, "enter"), { kind: "restore" })
  assert.deepEqual(k(stock, "enter"), { kind: "restore" })
  assert.deepEqual(k(mine, "s"), { kind: "save" })
  assert.equal(k(stock, "s").kind, "none", "only My layout can be saved")
  assert.equal(k(widget, "s").kind, "none")
  assert.equal(k(mine, "space").kind, "none")

  // escape: cancel an armed restore first, otherwise close
  assert.deepEqual(k(mine, "esc", { armed: true }), { kind: "disarm" })
  assert.deepEqual(k(mine, "esc", { armed: false }), { kind: "close" })
  assert.deepEqual(k(null, "esc"), { kind: "close" })

  // keys we do not own are left alone
  for (const t of ["q", "w", "tab", "z", "5", "c", "r", ""]) assert.equal(k(widget, t).kind, "none", "'" + t + "' is ignored")
}

// parentHeader / laneHeader / initialCursor / hintFor
{
  const rows = L.buildRows(config, plugins, "x.deck", false, {}, [])
  const header = i => rows[i].type === "header"
  const clock = L.findRow(rows, { id: "a.clock" })
  const centerHeader = L.parentHeader(rows, clock)
  assert.equal(rows[centerHeader].section, "center")
  assert.equal(L.parentHeader(rows, centerHeader), centerHeader, "a header is its own parent")

  const right = L.laneHeader(rows, clock, 1)
  assert.equal(rows[right].section, "right", "] from a center widget goes to the right lane")
  assert.equal(L.laneHeader(rows, clock, -1), centerHeader, "[ from inside a lane goes to its own header")
  assert.equal(rows[L.laneHeader(rows, centerHeader, -1)].section, "left", "[ from a header goes to the previous lane")
  const lastHeader = rows.map((r, i) => header(i) ? i : -1).filter(i => i >= 0).pop()
  assert.equal(L.laneHeader(rows, lastHeader, 1), lastHeader, "no lane after the last one")
  assert.equal(L.laneHeader(rows, 0, -1), 0, "no lane before the first one")

  assert.equal(rows[L.initialCursor(rows)].type, "widget", "the highlight starts on a widget")
  const folded = L.buildRows(config, plugins, "x.deck", false, { left: true, center: true, right: true, available: true }, [])
  assert.equal(L.initialCursor(folded), 0, "with everything folded, the first row")
  assert.equal(L.initialCursor([]), -1)

  assert.equal(L.hintFor(rows[clock], false), "Space off · 1 2 3 lane · ← lane header")
  assert.equal(L.hintFor(rows[centerHeader], false), "← → or Enter fold")
  assert.equal(L.hintFor({ type: "available" }, false), "Space switch on · 1 2 3 into a lane")
  assert.equal(L.hintFor({ type: "layout", kind: "mine", exists: true }, false), "Enter twice restore · s save")
  assert.equal(L.hintFor({ type: "layout", kind: "mine", exists: false }, false), "s save")
  assert.equal(L.hintFor({ type: "layout", kind: "default" }, false), "Enter twice restore")
  assert.equal(L.hintFor({ type: "layout", kind: "default" }, true), "Enter again to restore · Esc cancel")
  assert.equal(L.hintFor(null, false), "")
  assert.ok(L.HINT_KEYS.indexOf("Shift+↑↓") >= 0)
}

assert.deepEqual(L.parseJson("{bad", []), [])
assert.deepEqual(L.parseJson("", {}), {})
console.log("layout tests passed")

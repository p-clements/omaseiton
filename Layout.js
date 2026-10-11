.pragma library

// Pure layout logic for Omaseiton. No QML or Quickshell imports, so it runs
// under plain node for tests (see tests/layout.test.js).

var SECTIONS = ["left", "center", "right"]
var SECTION_LABELS = { left: "Left", center: "Center", right: "Right" }
var VERTICAL_LABELS = { left: "Start", center: "Center", right: "End" }

function parseJson(text, fallback) {
  try {
    var value = JSON.parse(String(text || ""))
    return value === null || value === undefined ? fallback : value
  } catch (e) {
    return fallback
  }
}

function pluginIndex(plugins) {
  var map = {}
  for (var i = 0; i < plugins.length; i++) map[plugins[i].id] = plugins[i]
  return map
}

function isBarWidget(plugin) {
  return !!plugin && Array.isArray(plugin.kinds) && plugin.kinds.indexOf("bar-widget") >= 0
}

// Flat list of rows for the panel: a header per section, a widget row per
// bar entry (in bar order), then an "available" header and one row per
// bar-widget plugin that is not currently placed on the bar.
function buildRows(config, plugins, selfId, vertical, collapsed, layouts) {
  collapsed = collapsed || {}
  var layout = (config && config.bar && config.bar.layout) || {}
  var byId = pluginIndex(plugins || [])
  var labels = vertical ? VERTICAL_LABELS : SECTION_LABELS
  var placed = {}
  var rows = []

  for (var s = 0; s < SECTIONS.length; s++) {
    var section = SECTIONS[s]
    var entries = Array.isArray(layout[section]) ? layout[section] : []
    rows.push({ type: "header", section: section, label: labels[section], count: entries.length, collapsed: !!collapsed[section] })
    for (var i = 0; i < entries.length; i++) {
      var id = entries[i].id
      var plugin = byId[id]
      placed[id] = true
      if (collapsed[section]) continue
      rows.push({
        type: "widget",
        id: id,
        name: plugin ? plugin.name : id,
        section: section,
        index: i,
        sectionSize: entries.length,
        firstParty: plugin ? !!plugin.firstParty : false,
        clonedFrom: plugin ? (plugin.clonedFrom || "") : "",
        canDisable: id !== selfId && (plugin ? plugin.canDisable !== false : true),
        isSelf: id === selfId
      })
    }
  }

  var available = []
  for (var j = 0; j < (plugins || []).length; j++) {
    var p = plugins[j]
    if (isBarWidget(p) && !placed[p.id]) available.push(p)
  }
  rows.push({ type: "header", section: "available", label: "Available", count: available.length, collapsed: !!collapsed.available })
  for (var k = 0; k < available.length; k++) {
    if (collapsed.available) break
    rows.push({
      type: "available",
      id: available[k].id,
      name: available[k].name,
      firstParty: !!available[k].firstParty,
      clonedFrom: available[k].clonedFrom || ""
    })
  }
  return rows.concat(buildLayoutRows(layouts, collapsed))
}

// The "Layouts" node: the stock Omarchy bar, the user's own saved layout, and
// the automatic snapshots taken before each restore (newest first).
function buildLayoutRows(layouts, collapsed) {
  collapsed = collapsed || {}
  var saved = Array.isArray(layouts) ? layouts : []
  var mine = null
  var autos = []
  for (var i = 0; i < saved.length; i++) {
    if (saved[i].slot === "mine") mine = saved[i]
    else if (String(saved[i].slot).indexOf("auto-") === 0) autos.push(saved[i])
  }
  var rows = [{ type: "header", section: "layouts", label: "Layouts", count: 2 + autos.length, collapsed: !!collapsed.layouts }]
  if (collapsed.layouts) return rows
  rows.push({ type: "layout", slot: "omarchy-default", kind: "default", name: "Omarchy default",
    note: "the stock bar (Omaseiton stays)", savedAt: "", widgets: 0, exists: true })
  rows.push({ type: "layout", slot: "mine", kind: "mine", name: "My layout",
    note: mine ? "" : "not saved yet", savedAt: mine ? mine.savedAt : "", widgets: mine ? mine.widgets : 0, exists: !!mine })
  for (var k = 0; k < autos.length; k++) {
    rows.push({ type: "layout", slot: autos[k].slot, kind: "auto", name: "Before a restore",
      note: "", savedAt: autos[k].savedAt, widgets: autos[k].widgets, exists: true })
  }
  return rows
}

function sectionSize(config, section) {
  var layout = (config && config.bar && config.bar.layout) || {}
  return Array.isArray(layout[section]) ? layout[section].length : 0
}

function merge(a, b) {
  var out = {}
  var key
  for (key in a) out[key] = a[key]
  for (key in b) out[key] = b[key]
  return out
}

// Placement object for `moveBarWidget`, or null when the move is a no-op.
// Always carries fromSection/fromIndex so widgets that allow several
// instances (like the spacer) move the right one.
//   up / down      reorder inside the section
//   prev / next    jump to the end of the previous / start of the next section
function computeMove(config, section, index, action) {
  var at = SECTIONS.indexOf(section)
  if (at < 0) return null
  var size = sectionSize(config, section)
  if (index < 0 || index >= size) return null
  var from = { fromSection: section, fromIndex: index }

  if (action === "up") {
    if (index === 0) return null
    return merge(from, { section: section, index: index - 1 })
  }
  if (action === "down") {
    if (index >= size - 1) return null
    return merge(from, { section: section, index: index + 1 })
  }
  if (action.indexOf("to-") === 0) {
    var target = action.slice(3)
    if (SECTIONS.indexOf(target) < 0 || target === section) return null
    return merge(from, { section: target, index: sectionSize(config, target) })
  }
  if (action === "prev") {
    if (at === 0) return null
    var prev = SECTIONS[at - 1]
    return merge(from, { section: prev, index: sectionSize(config, prev) })
  }
  if (action === "next") {
    if (at === SECTIONS.length - 1) return null
    return merge(from, { section: SECTIONS[at + 1], index: 0 })
  }
  return null
}

// Row index of a remembered cursor target. Targets are tried most precise
// first: a widget by lane and position, then a lane header, then a widget or
// available plugin by id (the id is what finds one of several spacers).
function findRow(rows, target) {
  if (!target) return -1
  var i
  if (target.section !== undefined && target.index !== undefined) {
    for (i = 0; i < rows.length; i++) {
      if (rows[i].type === "widget" && rows[i].section === target.section && rows[i].index === target.index) return i
    }
  }
  if (target.header) {
    for (i = 0; i < rows.length; i++) {
      if (rows[i].type === "header" && rows[i].section === target.header) return i
    }
  }
  if (target.id) {
    for (i = 0; i < rows.length; i++) {
      if ((rows[i].type === "available" || rows[i].type === "widget") && rows[i].id === target.id) return i
    }
  }
  return -1
}

// Next cursor stop from `from`, stepping by dir. Headers are stops too, so
// the keyboard can collapse and expand lanes.
function stepCursor(rows, from, dir) {
  var i = from + dir
  if (i < 0 || i >= rows.length) return from
  return i
}

// ---------------------------------------------------------------- keyboard
//
// Tokens are plain strings made from a key press: "up", "down", "left",
// "right", "home", "end", "enter", "space", "esc", with a "shift+" prefix when
// Shift is held, or the typed character for everything else ("j", "J", "1",
// "[", "x"...). Modifier combinations other than Shift produce no token.
//
// Plain keys move the highlight; Shift moves the widget. Up / down is the
// order inside a lane, left / right is the lane.

var HINT_KEYS = "↑↓ move · [ ] lanes · Shift+↑↓ order · Shift+←→ lane"

// What a key does for the highlighted row. Returns {kind: ...}; "none" means
// the key is not ours and should be left alone.
function resolveKey(row, token, ctx) {
  ctx = ctx || {}
  var none = { kind: "none" }
  var type = row ? row.type : ""

  if (token === "esc") return ctx.armed ? { kind: "disarm" } : { kind: "close" }
  if (token === "up" || token === "k") return { kind: "cursor", dy: -1 }
  if (token === "down" || token === "j") return { kind: "cursor", dy: 1 }
  if (token === "home" || token === "g") return { kind: "cursor", to: "first" }
  if (token === "end" || token === "G") return { kind: "cursor", to: "last" }
  if (token === "[") return { kind: "lane", dir: -1 }
  if (token === "]") return { kind: "lane", dir: 1 }
  if (!row) return none

  if (token === "left" || token === "h") {
    return type === "header" ? { kind: "fold", value: true } : { kind: "parent" }
  }
  if (token === "right" || token === "l") {
    return type === "header" ? { kind: "unfold" } : none
  }

  if (type === "widget") {
    if (token === "shift+up" || token === "K") return { kind: "move", action: "up" }
    if (token === "shift+down" || token === "J") return { kind: "move", action: "down" }
    if (token === "shift+left" || token === "H") return { kind: "move", action: "prev" }
    if (token === "shift+right" || token === "L") return { kind: "move", action: "next" }
    if (token === "1" || token === "2" || token === "3") return { kind: "send", lane: Number(token) - 1 }
    if (token === "space" || token === "x") return { kind: "toggle" }
    return none
  }
  if (type === "available") {
    if (token === "1" || token === "2" || token === "3") return { kind: "send", lane: Number(token) - 1 }
    if (token === "space" || token === "enter") return { kind: "toggle" }
    return none
  }
  if (type === "header") {
    if (token === "enter" || token === "space") return { kind: "foldToggle" }
    return none
  }
  if (type === "layout") {
    if (token === "enter") return { kind: "restore" }
    if (token === "s" && row.kind === "mine") return { kind: "save" }
    return none
  }
  return none
}

// The header row above `from` (or `from` itself when it is a header).
function parentHeader(rows, from) {
  for (var i = Math.min(from, rows.length - 1); i >= 0; i--) {
    if (rows[i].type === "header") return i
  }
  return from
}

// Nearest header strictly before (dir < 0) or after (dir > 0) `from`; stays
// put when there is none. From inside a lane, "before" is that lane's own header.
function laneHeader(rows, from, dir) {
  var i = from + dir
  while (i >= 0 && i < rows.length) {
    if (rows[i].type === "header") return i
    i += dir
  }
  return from
}

// Where the highlight starts: the first widget, otherwise the first row.
function initialCursor(rows) {
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].type === "widget") return i
  }
  return rows.length > 0 ? 0 : -1
}

// Second hint line: what the keys do for the highlighted row.
function hintFor(row, armed) {
  if (armed) return "Enter again to restore · Esc cancel"
  if (!row) return ""
  if (row.type === "widget") return "Space off · 1 2 3 lane · ← lane header"
  if (row.type === "header") return "← → or Enter fold"
  if (row.type === "available") return "Space switch on · 1 2 3 into a lane"
  if (row.type === "layout") {
    if (row.kind === "mine") return row.exists ? "Enter twice restore · s save" : "s save"
    return "Enter twice restore"
  }
  return ""
}


if (typeof module !== "undefined") {
  module.exports = {
    SECTIONS: SECTIONS, parseJson: parseJson, buildRows: buildRows, buildLayoutRows: buildLayoutRows, computeMove: computeMove,
    findRow: findRow, stepCursor: stepCursor, resolveKey: resolveKey, parentHeader: parentHeader,
    laneHeader: laneHeader, initialCursor: initialCursor, hintFor: hintFor, HINT_KEYS: HINT_KEYS
  }
}

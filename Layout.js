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
function buildRows(config, plugins, selfId, vertical) {
  var layout = (config && config.bar && config.bar.layout) || {}
  var byId = pluginIndex(plugins || [])
  var labels = vertical ? VERTICAL_LABELS : SECTION_LABELS
  var placed = {}
  var rows = []

  for (var s = 0; s < SECTIONS.length; s++) {
    var section = SECTIONS[s]
    var entries = Array.isArray(layout[section]) ? layout[section] : []
    rows.push({ type: "header", section: section, label: labels[section], count: entries.length })
    for (var i = 0; i < entries.length; i++) {
      var id = entries[i].id
      var plugin = byId[id]
      placed[id] = true
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
  rows.push({ type: "header", section: "available", label: "Available", count: available.length })
  for (var k = 0; k < available.length; k++) {
    rows.push({
      type: "available",
      id: available[k].id,
      name: available[k].name,
      firstParty: !!available[k].firstParty,
      clonedFrom: available[k].clonedFrom || ""
    })
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

// Row index of the widget at section/index, or of an available plugin by id.
function findRow(rows, target) {
  if (!target) return -1
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r.type === "widget" && r.section === target.section && r.index === target.index) return i
    if (r.type === "available" && target.id && r.id === target.id) return i
  }
  return -1
}

// Next cursor-able row (widget or available) from `from`, stepping by dir.
function stepCursor(rows, from, dir) {
  var i = from + dir
  while (i >= 0 && i < rows.length) {
    if (rows[i].type !== "header") return i
    i += dir
  }
  return from
}

if (typeof module !== "undefined") {
  module.exports = {
    SECTIONS: SECTIONS, parseJson: parseJson, buildRows: buildRows, computeMove: computeMove,
    findRow: findRow, stepCursor: stepCursor
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Layout.js" as Layout

// The Omaseiton dropdown: a small tree. Each lane (Left / Center / Right) is a
// collapsible parent and the bar widgets sit underneath it in bar order.
//
// On a row, the L / C / R buttons say which lane the widget is in (the current
// one is filled) and move it to another lane with one click. Two arrows reorder
// inside the lane, along the bar's own direction (left / right on a horizontal
// bar, up / down on a vertical one), and appear on the highlighted row.
//
// A "Layouts" node saves and restores whole bar layouts. Moves and toggles go
// through the shell's own IPC (the same calls `omarchy bar` and `omarchy plugin`
// make), one at a time. Only restoring a layout writes shell.json, and it takes
// a snapshot first (see scripts/layout.sh).
Item {
  id: root

  property QtObject bar: null
  property string selfId: ""
  property string stateDir: ""
  property string reopenFlag: ""

  signal closeRequested()

  readonly property Item focusItem: keys
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property var laneKeys: ["left", "center", "right"]
  readonly property var laneLetters: vertical ? ["S", "C", "E"] : ["L", "C", "R"]

  property var config: ({})
  property var plugins: []
  property var collapsed: ({ available: true, layouts: true })
  property var layouts: []
  property string armedSlot: ""
  property var rows: Layout.buildRows(config, plugins, selfId, vertical, collapsed, layouts)
  readonly property string layoutScript: Qt.resolvedUrl("scripts/layout.sh").toString().replace(/^file:\/\//, "")
  property int cursor: -1
  property var cursorTarget: null
  property bool busy: false

  readonly property int onBarCount: {
    var n = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].type === "header" && laneKeys.indexOf(rows[i].section) >= 0) n += rows[i].count
    return n
  }
  readonly property int availableCount: {
    for (var i = 0; i < rows.length; i++) if (rows[i].type === "header" && rows[i].section === "available") return rows[i].count
    return 0
  }

  // ------------------------------------------------------------- state

  function refresh() {
    if (!configProcess.running) configProcess.running = true
    if (!pluginsProcess.running) pluginsProcess.running = true
    if (!layoutsProcess.running) layoutsProcess.running = true
  }

  Process {
    id: configProcess
    command: ["omarchy-shell", "shell", "listShellConfig"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.config = Layout.parseJson(text, root.config)
        root.settleCursor()
      }
    }
  }

  Process {
    id: pluginsProcess
    command: ["omarchy-shell", "shell", "listPlugins"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.plugins = Layout.parseJson(text, root.plugins)
        root.settleCursor()
      }
    }
  }

  Process {
    id: layoutsProcess
    command: ["bash", root.layoutScript, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.layouts = Layout.parseJson(text, root.layouts)
        root.settleCursor()
      }
    }
  }

  // Which lanes are collapsed survives the bar rebuilding after every change
  // (and closing the dropdown), so it lives in a small state file.
  Process {
    id: collapsedLoad
    command: ["cat", root.stateDir + "/collapsed.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var saved = Layout.parseJson(text, {})
        if (saved && typeof saved === "object") root.collapsed = saved
      }
    }
  }

  function setCollapsed(section, value) {
    var next = JSON.parse(JSON.stringify(collapsed || {}))
    next[section] = value
    collapsed = next
    Quickshell.execDetached(["sh", "-c", 'mkdir -p "$1" && printf %s "$2" > "$1/collapsed.json"',
      "sh", stateDir, JSON.stringify(next)])
  }

  function toggleCollapse(section) {
    setCollapsed(section, !(collapsed && collapsed[section]))
  }

  // After a refresh, put the cursor back on the row the user just acted on.
  function settleCursor() {
    var at = Layout.findRow(rows, cursorTarget)
    if (at >= 0) cursor = at
    else if (cursor < 0 || cursor >= rows.length) cursor = Layout.stepCursor(rows, -1, 1)
    if (cursor >= 0 && cursor < rows.length && list.count > 0)
      list.positionViewAtIndex(cursor, ListView.Contain)
  }

  Component.onCompleted: {
    collapsedLoad.running = true
    refresh()
  }

  // ------------------------------------------------------------- commands

  // One IPC call at a time: each mutation rebuilds the bar, so overlapping
  // calls would act on stale indices.
  property var queue: []

  function run(argv) {
    queue = queue.concat([argv])
    pump()
  }

  function pump() {
    if (runner.running || queue.length === 0) return
    busy = true
    var next = queue[0]
    queue = queue.slice(1)
    runner.command = next
    runner.running = true
  }

  Process {
    id: runner
    onExited: {
      if (root.queue.length > 0) root.pump()
      else {
        root.busy = false
        root.refresh()
      }
    }
  }

  // Mutations rebuild every bar widget, Omaseiton included. Leave a breadcrumb
  // so the fresh instance reopens the dropdown instead of vanishing.
  function markReopen() {
    run(["mkdir", "-p", stateDir])
    run(["touch", reopenFlag])
  }

  function shellCall(method, args) {
    markReopen()
    run(["omarchy-shell", "shell", method].concat(args))
  }

  function moveRow(row, action) {
    var placement = Layout.computeMove(config, row.section, row.index, action)
    if (!placement) return
    // Never move a widget into a lane the user cannot see it land in.
    if (collapsed && collapsed[placement.section]) setCollapsed(placement.section, false)
    cursorTarget = { id: row.id }
    shellCall("moveBarWidget", [row.id, JSON.stringify(placement)])
  }

  // Pressing a lane button: move a bar widget there, or switch an available
  // one on in that lane.
  function sendToLane(row, laneIndex) {
    var lane = laneKeys[laneIndex]
    if (row.type === "available") {
      if (collapsed && collapsed[lane]) setCollapsed(lane, false)
      cursorTarget = { id: row.id }
      shellCall("enablePlugin", [row.id, JSON.stringify({ section: lane })])
    } else if (row.type === "widget") {
      moveRow(row, "to-" + lane)
    }
  }

  function toggleRow(row) {
    if (row.type === "widget") {
      if (!row.canDisable) return
      cursorTarget = null
      shellCall("setPluginEnabled", [row.id, "false"])
    } else if (row.type === "available") {
      cursorTarget = { id: row.id }
      shellCall("enablePlugin", [row.id, "{}"])
    }
  }

  function terminal(command) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", command])
    closeRequested()
  }

  function stamp(iso) {
    var d = new Date(iso)
    return isNaN(d.getTime()) ? "" : Qt.formatDateTime(d, "d MMM HH:mm")
  }

  function saveMine() {
    run(["bash", layoutScript, "save", "mine"])
  }

  // Restoring replaces the whole bar, so it takes two presses. The script
  // snapshots the current layout first, so there is always a way back.
  function restoreLayout(row) {
    if (!row.exists) return
    if (armedSlot !== row.slot) {
      armedSlot = row.slot
      armTimer.restart()
      return
    }
    armedSlot = ""
    markReopen()
    run(["bash", layoutScript, row.kind === "default" ? "defaults" : "restore", row.slot])
  }

  Timer {
    id: armTimer
    interval: 4000
    onTriggered: root.armedSlot = ""
  }

  // ------------------------------------------------------------- pieces

  // A small square button: a lane letter or an arrow. `current` fills it.
  component Chip: Item {
    id: chip
    property string label: ""
    property bool current: false
    property bool dimmed: false
    property bool shown: true
    property bool urgent: false
    signal clicked()

    implicitWidth: label.length > 1 ? Math.max(Style.space(22), chipText.implicitWidth + Style.space(14)) : Style.space(22)
    implicitHeight: Style.space(22)
    width: implicitWidth
    height: implicitHeight
    opacity: !shown ? 0 : (dimmed ? 0.3 : 1)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: chip.current
        ? Style.selectedFillFor(root.fg, Color.accent)
        : (chipMouse.containsMouse && chip.enabled ? Style.hoverFillFor(root.fg, Color.accent) : "transparent")
      border.width: chip.current ? 1 : 0
      border.color: Color.accent
      Behavior on color { ColorAnimation { duration: 60 } }
    }
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      textFormat: Text.PlainText
      color: chip.urgent ? Color.urgent : (chip.current ? Color.accent : root.fg)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: chip.current
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: chip.enabled
      onClicked: chip.clicked()
    }
  }

  // ------------------------------------------------------------- layout

  readonly property int rowHeight: Style.spacing.popupRowHeight + Style.space(6)
  readonly property int headerHeight: Style.space(28)
  readonly property int indent: Style.space(14)

  PanelKeyCatcher {
    id: keys
    anchors.fill: parent
    onCloseRequested: root.closeRequested()
    onMoveRequested: function(dx, dy) {
      if (dy !== 0) {
        root.cursor = Layout.stepCursor(root.rows, root.cursor, dy)
        list.positionViewAtIndex(root.cursor, ListView.Contain)
        return
      }
      var row = root.rows[root.cursor]
      if (!row) return
      if (row.type === "header") root.setCollapsed(row.section, dx < 0)
      else if (row.type === "widget") {
        // Along the bar's own direction: left / right reorders on a horizontal
        // bar; on a vertical bar those keys change lane instead.
        if (root.vertical) root.moveRow(row, dx < 0 ? "prev" : "next")
        else root.moveRow(row, dx < 0 ? "up" : "down")
      }
    }
    onActivateRequested: {
      var row = root.rows[root.cursor]
      if (!row) return
      if (row.type === "header") root.toggleCollapse(row.section)
      else if (row.type === "layout") root.restoreLayout(row)
      else root.toggleRow(row)
    }
    onTextKey: function(t) {
      var row = root.rows[root.cursor]
      if (!row || row.type === "header") return
      if (row.type === "layout") {
        if (t === "s" && row.kind === "mine") root.saveMine()
        return
      }
      if (t === "1" || t === "2" || t === "3") root.sendToLane(row, Number(t) - 1)
      else if (row.type === "widget" && root.vertical && t === "K") root.moveRow(row, "up")
      else if (row.type === "widget" && root.vertical && t === "J") root.moveRow(row, "down")
      else if (row.type === "widget" && !root.vertical && t === "H") root.moveRow(row, "up")
      else if (row.type === "widget" && !root.vertical && t === "L") root.moveRow(row, "down")
    }

    Column {
      anchors.fill: parent
      spacing: Style.space(8)

      PanelHero {
        id: hero
        title: "Omaseiton"
        meta: root.onBarCount + " on the bar · " + root.availableCount + " available"
        foreground: root.fg
        iconComponent: Component {
          Text {
            text: String.fromCodePoint(0xF0431)
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }
        }
      }

      Text {
        id: hint
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.laneLetters.join(" ") + " pick the lane · " + (root.vertical ? "▲ ▼" : "◀ ▶") + " reorder · click a lane name to fold it"
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { foreground: root.fg }

      ListView {
        id: list
        width: parent.width
        height: parent.height - hero.height - hint.height - footer.height - Style.space(8) * 5 - 2
        clip: true
        model: root.rows
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: false

        delegate: Item {
          id: delegateRoot
          required property var modelData
          required property int index
          readonly property bool isHeader: modelData.type === "header"
          readonly property bool isAvailable: modelData.type === "available"
          readonly property bool isWidget: modelData.type === "widget"
          readonly property bool isLayout: modelData.type === "layout"
          readonly property bool hot: root.cursor === index
          readonly property int laneIndex: isWidget ? root.laneKeys.indexOf(modelData.section) : -1

          width: list.width
          height: isHeader ? root.headerHeight : root.rowHeight

          // ---- lane header (the tree's parent node)
          CursorSurface {
            visible: delegateRoot.isHeader
            anchors.fill: parent
            anchors.topMargin: Style.space(2)
            hasCursor: delegateRoot.hot
            foreground: root.fg

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.cursor = delegateRoot.index
              onClicked: {
                root.cursor = delegateRoot.index
                root.toggleCollapse(delegateRoot.modelData.section)
              }
            }

            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                text: delegateRoot.isHeader && delegateRoot.modelData.collapsed ? "▸" : "▾"
                textFormat: Text.PlainText
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              PanelSectionHeader {
                foreground: root.fg
                topPadding: 0
                text: delegateRoot.isHeader
                  ? (delegateRoot.modelData.label.toUpperCase() + "  " + delegateRoot.modelData.count)
                  : ""
              }
            }
          }

          // ---- widget / available row (a child node)
          Rectangle {
            // the tree's vertical guide line
            visible: !delegateRoot.isHeader
            x: Style.space(12)
            width: 1
            height: parent.height
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
          }

          CursorSurface {
            visible: !delegateRoot.isHeader
            anchors.fill: parent
            anchors.leftMargin: root.indent + Style.space(6)
            anchors.topMargin: Style.space(1)
            anchors.bottomMargin: Style.space(1)
            hasCursor: delegateRoot.hot
            foreground: root.fg

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.cursor = delegateRoot.index
              onClicked: root.cursor = delegateRoot.index
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(6)

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - actions.width - parent.spacing
                spacing: 0

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: delegateRoot.isHeader ? "" : delegateRoot.modelData.name
                  color: delegateRoot.isAvailable ? root.dim : root.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: {
                    if (delegateRoot.isHeader) return ""
                    var m = delegateRoot.modelData
                    if (delegateRoot.isLayout) {
                      if (m.note) return m.note
                      var when = root.stamp(m.savedAt)
                      return (when ? when + " · " : "") + m.widgets + " widgets"
                    }
                    var note = m.isSelf ? "this widget" : (m.firstParty ? "built-in" : "plugin")
                    if (m.clonedFrom) note += " · clone of " + m.clonedFrom
                    return m.id + " · " + note
                  }
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: actions
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                // reorder inside the lane: only on the highlighted row
                Chip {
                  visible: delegateRoot.isWidget
                  label: root.vertical ? "▲" : "◀"
                  shown: delegateRoot.hot
                  enabled: delegateRoot.hot && delegateRoot.isWidget && delegateRoot.modelData.index > 0
                  dimmed: delegateRoot.hot && !enabled
                  onClicked: root.moveRow(delegateRoot.modelData, "up")
                }
                Chip {
                  visible: delegateRoot.isWidget
                  label: root.vertical ? "▼" : "▶"
                  shown: delegateRoot.hot
                  enabled: delegateRoot.hot && delegateRoot.isWidget
                    && delegateRoot.modelData.index < delegateRoot.modelData.sectionSize - 1
                  dimmed: delegateRoot.hot && !enabled
                  onClicked: root.moveRow(delegateRoot.modelData, "down")
                }

                Item { width: Style.space(4); height: 1; visible: delegateRoot.isWidget }

                // lane picker: the current lane is filled, the others move it there
                Chip {
                  visible: delegateRoot.isLayout && delegateRoot.modelData.kind === "mine"
                  label: "Save"
                  onClicked: root.saveMine()
                }
                Chip {
                  visible: delegateRoot.isLayout
                  label: root.armedSlot === delegateRoot.modelData.slot ? "Sure?"
                    : (delegateRoot.modelData.kind === "default" ? "Reset" : "Restore")
                  urgent: root.armedSlot === delegateRoot.modelData.slot
                  enabled: delegateRoot.isLayout && delegateRoot.modelData.exists
                  dimmed: delegateRoot.isLayout && !delegateRoot.modelData.exists
                  onClicked: root.restoreLayout(delegateRoot.modelData)
                }

                Repeater {
                  model: delegateRoot.isLayout ? 0 : 3
                  Chip {
                    required property int index
                    label: root.laneLetters[index]
                    current: delegateRoot.laneIndex === index
                    onClicked: root.sendToLane(delegateRoot.modelData, index)
                  }
                }

                Item { width: Style.space(4); height: 1; visible: !delegateRoot.isLayout }

                ToggleSwitch {
                  visible: !delegateRoot.isLayout
                  anchors.verticalCenter: parent.verticalCenter
                  cursorRing: false
                  trackHeight: Style.space(18)
                  checked: !delegateRoot.isAvailable
                  opacity: delegateRoot.isAvailable || delegateRoot.isLayout || delegateRoot.modelData.canDisable ? 1 : 0.35
                  foreground: root.fg
                  onToggled: root.toggleRow(delegateRoot.modelData)
                }
              }
            }
          }
        }
      }

      PanelSeparator { foreground: root.fg }

      Row {
        id: footer
        width: parent.width
        spacing: Style.space(6)

        Button {
          iconText: String.fromCodePoint(0xF059F)
          text: "Browse"
          tooltipText: "Open the Omarchy plugin marketplace"
          foreground: root.fg
          onClicked: {
            Quickshell.execDetached(["omarchy-launch-webapp", "https://plugins.omarchy.org"])
            root.closeRequested()
          }
        }
        Button {
          iconText: "+"
          text: "Add"
          tooltipText: "Install a plugin from a git URL"
          foreground: root.fg
          onClicked: root.terminal("omarchy-plugin-add")
        }
        Button {
          iconText: "↻"
          text: "Update"
          tooltipText: "Update installed git plugins"
          foreground: root.fg
          onClicked: root.terminal("omarchy-plugin-update")
        }
      }
    }
  }
}

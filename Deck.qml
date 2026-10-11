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
// one is filled) and move it to another lane with one click. Two arrows (up and
// down, matching Shift+Up / Shift+Down) reorder
// inside the lane and appear on the highlighted row.
//
// A "Layouts" node saves and restores whole bar layouts. Moves, lane changes and
// toggles go through the shell's own IPC (the same calls `omarchy bar` and
// `omarchy plugin` make), one at a time. Restoring a layout, or the Omarchy
// default, runs scripts/layout.sh, which is the only thing here that writes
// shell.json; it snapshots first. Both are described in the README.
Item {
  id: root

  property QtObject bar: null
  property string selfId: ""
  property string stateDir: ""
  property string reopenFlag: ""
  property string screenName: ""

  signal closeRequested()

  readonly property Item focusItem: keys
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property var laneKeys: Layout.SECTIONS
  readonly property var laneLetters: vertical ? ["S", "C", "E"] : ["L", "C", "R"]

  property var config: ({})
  property var plugins: []
  property var collapsed: ({ available: true, layouts: true })
  property var layouts: []
  property string armedSlot: ""
  property var rows: Layout.buildRows(config, plugins, selfId, vertical, collapsed, layouts)
  readonly property string layoutScript: Qt.resolvedUrl("scripts/layout.sh").toString().replace(/^file:\/\//, "")
  readonly property string updateScript: Qt.resolvedUrl("scripts/update.sh").toString().replace(/^file:\/\//, "")
  property int cursor: -1
  property var cursorTarget: null
  property bool placed: false
  property bool busy: false
  property bool layoutBusy: false
  readonly property bool working: busy || layoutBusy
  property string statusText: ""
  property string lastOutput: ""
  property var currentArgv: []

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

  // Folding or unfolding a lane the user is looking at. Changing the rows
  // replaces the list's contents, and Qt then resets the view to the top, which
  // loses the lane when it is far down (Right, Available, Layouts). That reset
  // is applied when the list next lays out, after any code that runs straight
  // away, so force the layout first and then scroll to the lane. A second pass
  // a moment later covers a reset that still lands after that.
  function foldLane(section, value) {
    setCollapsed(section, value)
    Qt.callLater(function() { settleFold(section) })
    foldReveal.section = section
    foldReveal.restart()
  }

  function settleFold(section) {
    var at = Layout.findRow(rows, { header: section })
    if (at >= 0) cursor = at
    list.forceLayout()
    // Lane at the top, so an unfolded lane shows its widgets beneath it.
    if (cursor >= 0 && cursor < rows.length) list.positionViewAtIndex(cursor, ListView.Beginning)
  }

  Timer {
    id: foldReveal
    property string section: ""
    interval: 60
    onTriggered: root.settleFold(section)
  }

  function toggleCollapse(section) {
    foldLane(section, !(collapsed && collapsed[section]))
  }

  // The bar rebuilds after every change, which destroys this panel and builds
  // a new one. Where the highlight was is remembered in a small file so the
  // new panel can put it back on the widget that just moved (so a key such as
  // Shift+Down can be pressed again and again).
  Process {
    id: cursorLoad
    command: ["find", root.stateDir + "/cursor.json", "-newermt", "10 seconds ago", "-exec", "cat", "{}", ";"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var saved = Layout.parseJson(text, null)
        Quickshell.execDetached(["rm", "-f", root.stateDir + "/cursor.json"])
        if (saved && typeof saved === "object") {
          root.cursorTarget = saved
          root.settleCursor()
        }
      }
    }
  }

  function rememberCursor(target) {
    cursorTarget = target
    Quickshell.execDetached(["sh", "-c", 'mkdir -p "$1" && printf %s "$2" > "$1/cursor.json"',
      "sh", stateDir, JSON.stringify(target)])
  }

  // The pointer rests over the list while the keyboard is used. Moving a widget
  // rebuilds the panel, and scrolling the list shifts rows under the pointer;
  // Qt answers both with a synthetic "mouse moved" event that would drag the
  // highlight to whatever row is now under it. Only a pointer whose window
  // position really changed counts. The first event after opening just records
  // where the pointer is.
  property real pointerX: NaN
  property real pointerY: NaN

  function pointerMoved(area, mouse) {
    var p = area.mapToItem(null, mouse.x, mouse.y)
    if (isNaN(pointerX)) {
      pointerX = p.x
      pointerY = p.y
      return false
    }
    if (Math.abs(p.x - pointerX) < 2 && Math.abs(p.y - pointerY) < 2) return false
    pointerX = p.x
    pointerY = p.y
    return true
  }

  function revealCursor() {
    if (cursor >= 0 && cursor < rows.length && list.count > 0)
      list.positionViewAtIndex(cursor, ListView.Contain)
  }

  // Put the highlight on the remembered row, or on the first widget the first
  // time. Waits until the bar layout and plugin list have both arrived.
  function settleCursor() {
    if (!config || !config.bar || plugins.length === 0) return
    var target = cursorTarget
    var at = Layout.findRow(rows, target)
    if (at >= 0 && target.id && rows[at].id !== target.id) {
      // The refreshes arrive in any order; this row is whatever sits at that
      // position in the not-yet-updated list. Follow the widget by id for now
      // and keep the target until the list catches up.
      var byId = Layout.findRow(rows, { id: target.id })
      if (byId >= 0) cursor = byId
    } else if (at >= 0) {
      cursor = at
      cursorTarget = null
    } else if (!placed || cursor < 0 || cursor >= rows.length) {
      cursor = Layout.initialCursor(rows)
    }
    placed = true
    revealCursor()
  }

  Component.onCompleted: {
    collapsedLoad.running = true
    cursorLoad.running = true
    refresh()
    // Keys only work once this panel holds keyboard focus. The popup asks for
    // it before this content exists, so ask again from in here.
    Qt.callLater(function() { keys.forceActiveFocus() })
    focusRetry.start()
  }

  Timer {
    id: focusRetry
    interval: 150
    onTriggered: keys.forceActiveFocus()
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
    currentArgv = next
    runner.command = next
    runner.running = true
  }

  Process {
    id: runner
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastOutput = text
    }
    onExited: function(exitCode, exitStatus) {
      // The shell answers an IPC call with "ok", or with a word saying why not
      // (with exit status 0), so look at both.
      var said = String(root.lastOutput).trim()
      var asked = root.currentArgv.length > 0 ? root.currentArgv[0] : ""
      if (asked === "omarchy-shell" && said !== "" && said !== "ok") root.showStatus("The shell said: " + said.slice(0, 60))
      else if (exitCode !== 0) root.showStatus("That did not work (exit " + exitCode + ")")
      root.lastOutput = ""
      if (root.queue.length > 0) root.pump()
      else {
        root.busy = false
        root.refresh()
      }
    }
  }

  function showStatus(message) {
    statusText = message
    statusTimer.restart()
  }

  Timer {
    id: statusTimer
    interval: 6000
    onTriggered: root.statusText = ""
  }

  // Mutations rebuild every bar widget, Omaseiton included. Leave a breadcrumb
  // so the fresh instance reopens the dropdown instead of vanishing. There is one
  // bar per monitor, so the breadcrumb says which monitor's dropdown to reopen.
  function markReopen() {
    run(["sh", "-c", 'mkdir -p "$1" && printf %s "$2" > "$3"', "sh", stateDir, screenName, reopenFlag])
  }

  function shellCall(method, args) {
    markReopen()
    run(["omarchy-shell", "shell", method].concat(args))
  }

  function moveRow(row, action) {
    if (working) return
    var placement = Layout.computeMove(config, row.section, row.index, action)
    if (!placement) return
    // Never move a widget into a lane the user cannot see it land in.
    if (collapsed && collapsed[placement.section]) setCollapsed(placement.section, false)
    rememberCursor({ id: row.id, section: placement.section, index: placement.index })
    shellCall("moveBarWidget", [row.id, JSON.stringify(placement)])
  }

  // Pressing a lane button: move a bar widget there, or switch an available
  // one on in that lane.
  function sendToLane(row, laneIndex) {
    if (working) return
    var lane = laneKeys[laneIndex]
    if (row.type === "available") {
      if (collapsed && collapsed[lane]) setCollapsed(lane, false)
      rememberCursor({ id: row.id })
      shellCall("enablePlugin", [row.id, JSON.stringify({ section: lane })])
    } else if (row.type === "widget") {
      moveRow(row, "to-" + lane)
    }
  }

  function toggleRow(row) {
    if (working) return
    if (row.type === "widget") {
      if (!row.canDisable) return
      // Leave the highlight on the neighbour that takes its place.
      rememberCursor(row.sectionSize > 1
        ? { section: row.section, index: Math.min(row.index, row.sectionSize - 2) }
        : { header: row.section })
      shellCall("setPluginEnabled", [row.id, "false"])
    } else if (row.type === "available") {
      rememberCursor({ id: row.id })
      shellCall("enablePlugin", [row.id, "{}"])
    }
  }

  // Quote a value for the shell command line that the terminal launcher builds.
  function shq(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
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
    if (working) return
    run(["bash", layoutScript, "save", "mine"])
  }

  // Restoring replaces the bar's layout, so it takes two presses. The script
  // snapshots the current layout first, so there is always a way back. It runs
  // detached: the bar rebuilds the moment shell.json changes, and that destroys
  // this panel, which must not take the script's last steps down with it.
  function restoreLayout(row) {
    if (working || !row.exists) return
    if (armedSlot !== row.slot) {
      armedSlot = row.slot
      armTimer.restart()
      return
    }
    armedSlot = ""
    layoutBusy = true
    layoutBusyTimer.restart()
    Quickshell.execDetached(["env", "OMASEITON_REOPEN_FLAG=" + reopenFlag, "OMASEITON_REOPEN_SCREEN=" + screenName,
      "bash", layoutScript, row.kind === "default" ? "defaults" : "restore", row.slot])
    layoutRefresh.restart()
  }

  // If the panel survives (the script failed, say), pick up the real state.
  Timer {
    id: layoutBusyTimer
    interval: 4000
    onTriggered: root.layoutBusy = false
  }
  Timer {
    id: layoutRefresh
    interval: 1800
    onTriggered: root.refresh()
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

  // A Shift press has to reach us, and Omarchy's PanelKeyCatcher ignores
  // modifiers, so Omaseiton reads keys itself. Plain keys move the highlight;
  // Shift moves the widget: up / down is the order in a lane, left / right is
  // the lane. See Layout.resolveKey for the full table.
  function keyToken(event) {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return ""
    var name = ""
    switch (event.key) {
      case Qt.Key_Up: name = "up"; break
      case Qt.Key_Down: name = "down"; break
      case Qt.Key_Left: name = "left"; break
      case Qt.Key_Right: name = "right"; break
      case Qt.Key_Home: name = "home"; break
      case Qt.Key_End: name = "end"; break
      case Qt.Key_Return:
      case Qt.Key_Enter: name = "enter"; break
      case Qt.Key_Space: name = "space"; break
      case Qt.Key_Escape: name = "esc"; break
    }
    if (name !== "") return ((event.modifiers & Qt.ShiftModifier) ? "shift+" : "") + name
    // Letters come from the key itself, not from the text it produced, so
    // CapsLock cannot turn "j" (move down the list) into "J" (move the widget).
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) {
      var letter = String.fromCharCode(event.key).toLowerCase()
      return (event.modifiers & Qt.ShiftModifier) ? letter.toUpperCase() : letter
    }
    return event.text
  }

  // Returns true when the key was ours.
  function handleKey(token, isRepeat) {
    var row = rows[cursor] || null
    var action = Layout.resolveKey(row, token, { armed: armedSlot !== "" })
    if (action.kind === "none") return false

    // While a change is being applied the bar is about to rebuild: ignore
    // anything that would change it again, so keys cannot act on stale rows.
    // A key held down repeats; that must never repeat a change (switching off
    // widget after widget, or confirming a restore that wanted two deliberate presses).
    var changes = action.kind === "move" || action.kind === "send" || action.kind === "toggle"
      || action.kind === "restore" || action.kind === "save"
    if (changes && (working || isRepeat)) return true

    switch (action.kind) {
      case "cursor":
        cursor = action.dy ? Layout.stepCursor(rows, cursor, action.dy)
          : (action.to === "first" ? 0 : Math.max(0, rows.length - 1))
        revealCursor()
        break
      case "lane":
        cursor = Layout.laneHeader(rows, cursor < 0 ? 0 : cursor, action.dir)
        revealCursor()
        break
      case "parent":
        cursor = Layout.parentHeader(rows, cursor)
        revealCursor()
        break
      case "fold": foldLane(row.section, action.value); break
      case "foldToggle": toggleCollapse(row.section); break
      case "unfold":
        if (row.collapsed) foldLane(row.section, false)
        else if (cursor + 1 < rows.length && rows[cursor + 1].type !== "header") {
          cursor = cursor + 1
          revealCursor()
        }
        break
      case "move": moveRow(row, action.action); break
      case "send": sendToLane(row, action.lane); break
      case "toggle": toggleRow(row); break
      case "restore": restoreLayout(row); break
      case "save": saveMine(); break
      case "disarm":
        armedSlot = ""
        armTimer.stop()
        break
      case "close": closeRequested(); break
    }
    return true
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onPressed: function(event) {
      var token = root.keyToken(event)
      if (token !== "" && root.handleKey(token, event.isAutoRepeat)) event.accepted = true
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

      Column {
        id: hint
        width: parent.width
        spacing: Style.space(2)

        // the keys that always work
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: Layout.HINT_KEYS
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        // what the keys do for the highlighted row; a fixed height, so the
        // list below does not jump as the highlight moves
        Text {
          width: parent.width
          height: Style.font.caption + Style.space(6)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.statusText !== "" ? root.statusText : Layout.hintFor(root.rows[root.cursor] || null, root.armedSlot !== "")
          color: root.statusText !== "" ? Color.urgent : Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
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
              id: headerMouse
              anchors.fill: parent
              hoverEnabled: true
              onPositionChanged: function(mouse) {
                if (root.pointerMoved(headerMouse, mouse)) root.cursor = delegateRoot.index
              }
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
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              onPositionChanged: function(mouse) {
                if (root.pointerMoved(rowMouse, mouse)) root.cursor = delegateRoot.index
              }
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
                      return (when ? when + " · " : "") + m.widgets + " plugins"
                    }
                    var note = m.isSelf ? "this plugin" : (m.firstParty ? "built-in" : "plugin")
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
                  label: "▲"
                  shown: delegateRoot.hot
                  enabled: delegateRoot.hot && delegateRoot.isWidget && delegateRoot.modelData.index > 0
                  dimmed: delegateRoot.hot && !enabled
                  onClicked: root.moveRow(delegateRoot.modelData, "up")
                }
                Chip {
                  visible: delegateRoot.isWidget
                  label: "▼"
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
                  busy: root.working
                  interactive: delegateRoot.isAvailable || !!delegateRoot.modelData.canDisable
                  opacity: delegateRoot.isAvailable || delegateRoot.modelData.canDisable ? 1 : 0.35
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
          tooltipText: "Check installed git plugins for updates"
          foreground: root.fg
          onClicked: root.terminal("bash " + root.shq(root.updateScript))
        }
      }
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Layout.js" as Layout

// The Omadeck dropdown: every bar widget grouped by lane, with reorder,
// lane-jump and on/off controls, plus shortcuts to the plugin ecosystem.
//
// All changes go through the shell's own IPC (the same calls `omarchy bar`
// and `omarchy plugin` make), one at a time. Omadeck never writes shell.json.
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

  property var config: ({})
  property var plugins: []
  property var rows: Layout.buildRows(config, plugins, selfId, vertical)
  property int cursor: -1
  property var cursorTarget: null
  property bool resetArmed: false
  property bool busy: false

  readonly property int onBarCount: {
    var n = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].type === "widget") n++
    return n
  }
  readonly property int availableCount: {
    var n = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].type === "available") n++
    return n
  }

  // ------------------------------------------------------------- state

  function refresh() {
    if (!configProcess.running) configProcess.running = true
    if (!pluginsProcess.running) pluginsProcess.running = true
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

  // After a refresh, put the cursor back on the row the user just acted on.
  function settleCursor() {
    var at = Layout.findRow(rows, cursorTarget)
    if (at >= 0) cursor = at
    else if (cursor < 0 || cursor >= rows.length || rows[cursor].type === "header")
      cursor = Layout.stepCursor(rows, -1, 1)
    if (cursor >= 0 && cursor < rows.length && list.count > 0)
      list.positionViewAtIndex(cursor, ListView.Contain)
  }

  Component.onCompleted: refresh()

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

  // Mutations rebuild every bar widget, Omadeck included. Leave a breadcrumb
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
    cursorTarget = { section: placement.section, index: placement.index }
    shellCall("moveBarWidget", [row.id, JSON.stringify(placement)])
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

  function resetLayout() {
    if (!resetArmed) {
      resetArmed = true
      resetTimer.restart()
      return
    }
    resetArmed = false
    markReopen()
    run(["omarchy", "bar", "defaults"])
  }

  Timer {
    id: resetTimer
    interval: 4000
    onTriggered: root.resetArmed = false
  }

  // ------------------------------------------------------------- layout

  readonly property int rowHeight: Style.spacing.popupRowHeight + Style.space(6)
  readonly property int headerHeight: Style.space(26)

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
      if (row && row.type === "widget") root.moveRow(row, dx < 0 ? "prev" : "next")
    }
    onActivateRequested: {
      var row = root.rows[root.cursor]
      if (row) root.toggleRow(row)
    }
    onTextKey: function(t) {
      var row = root.rows[root.cursor]
      if (!row || row.type !== "widget") return
      if (t === "K") root.moveRow(row, "up")
      else if (t === "J") root.moveRow(row, "down")
    }

    Column {
      anchors.fill: parent
      spacing: Style.space(8)

      PanelHero {
        id: hero
        title: "Omadeck"
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

      PanelSeparator { foreground: root.fg }

      ListView {
        id: list
        width: parent.width
        height: parent.height - hero.height - footer.height - Style.space(8) * 4 - 2
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
          readonly property bool hot: root.cursor === index

          width: list.width
          height: isHeader ? root.headerHeight : root.rowHeight

          PanelSectionHeader {
            visible: delegateRoot.isHeader
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            foreground: root.fg
            text: delegateRoot.isHeader
              ? (delegateRoot.modelData.label.toUpperCase() + "  " + delegateRoot.modelData.count)
              : ""
          }

          CursorSurface {
            visible: !delegateRoot.isHeader
            anchors.fill: parent
            anchors.topMargin: Style.space(1)
            anchors.bottomMargin: Style.space(1)
            hasCursor: delegateRoot.hot
            foreground: root.fg

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onPositionChanged: root.cursor = delegateRoot.index
              onEntered: root.cursor = delegateRoot.index
              onClicked: root.cursor = delegateRoot.index
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(4)

              Column {
                id: labels
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

                PanelActionButton {
                  visible: !delegateRoot.isAvailable && !delegateRoot.isHeader
                  enabled: delegateRoot.modelData.section !== "left"
                  iconText: "←"
                  tooltipText: root.vertical ? "Move to the previous lane" : "Move to the lane on the left"
                  foreground: root.fg
                  onClicked: root.moveRow(delegateRoot.modelData, "prev")
                }
                PanelActionButton {
                  visible: !delegateRoot.isAvailable && !delegateRoot.isHeader
                  enabled: delegateRoot.modelData.index > 0
                  iconText: "↑"
                  tooltipText: "Move earlier"
                  foreground: root.fg
                  onClicked: root.moveRow(delegateRoot.modelData, "up")
                }
                PanelActionButton {
                  visible: !delegateRoot.isAvailable && !delegateRoot.isHeader
                  enabled: delegateRoot.modelData.index < delegateRoot.modelData.sectionSize - 1
                  iconText: "↓"
                  tooltipText: "Move later"
                  foreground: root.fg
                  onClicked: root.moveRow(delegateRoot.modelData, "down")
                }
                PanelActionButton {
                  visible: !delegateRoot.isAvailable && !delegateRoot.isHeader
                  enabled: delegateRoot.modelData.section !== "right"
                  iconText: "→"
                  tooltipText: root.vertical ? "Move to the next lane" : "Move to the lane on the right"
                  foreground: root.fg
                  onClicked: root.moveRow(delegateRoot.modelData, "next")
                }
                ToggleSwitch {
                  visible: !delegateRoot.isHeader
                  anchors.verticalCenter: parent.verticalCenter
                  cursorRing: false
                  trackHeight: Style.space(18)
                  checked: !delegateRoot.isAvailable
                  opacity: delegateRoot.isHeader || delegateRoot.isAvailable || delegateRoot.modelData.canDisable ? 1 : 0.35
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
        Button {
          iconText: "↺"
          text: root.resetArmed ? "Sure?" : "Reset"
          tooltipText: "Restore the default bar layout (click twice)"
          foreground: root.resetArmed ? Color.urgent : root.fg
          onClicked: root.resetLayout()
        }
      }
    }
  }
}

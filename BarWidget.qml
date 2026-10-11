import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: Runtime.pluginId

  property bool opened: false
  property bool popoutSwitchClosing: false

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omaseiton"
  readonly property string reopenFlag: stateDir + "/reopen"

  // The name of the monitor this bar instance is on. There is one instance per
  // monitor, and only the one whose dropdown was open should reopen.
  readonly property string screenName: {
    var window = button.QsWindow.window
    return window && window.screen ? String(window.screen.name) : ""
  }

  function open() {
    popoutSwitchClosing = false
    opened = true
  }
  function close() { opened = false }
  function closeForPopoutSwitch() { popoutSwitchClosing = true; close() }

  // Moving or toggling a widget rebuilds the whole bar, destroying this
  // instance mid-use. The dropdown leaves a fresh flag file, containing its
  // monitor's name, before each change; the replacement instance on that
  // monitor sees it and reopens straight away. The others leave it alone.
  Process {
    id: reopenCheck
    // prints "found" and then the file's contents, only if the file is fresh
    command: ["find", root.reopenFlag, "-newermt", "10 seconds ago", "-printf", "found\n", "-exec", "cat", "{}", ";"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n")
        if (lines[0] !== "found") return
        var wanted = lines.slice(1).join("").trim()
        // an empty flag (no monitor recorded) reopens on every monitor
        if (wanted === "" || wanted === root.screenName) {
          root.open()
          Quickshell.execDetached(["rm", "-f", root.reopenFlag])
        }
      }
    }
  }
  Component.onCompleted: reopenCheck.running = true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Emblem {
        foreground: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }
    }
    active: root.opened
    onPressed: b => {
      if (b !== Qt.LeftButton) return
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    padding: 12
    borderSpec: Border.flat(Color.accent, 2)
    contentWidth: 372
    contentHeight: 480
    focusTarget: content.item ? content.item.focusItem : null

    Loader {
      id: content
      anchors.fill: parent
      focus: true
      active: root.opened
      sourceComponent: Deck {
        bar: root.bar
        selfId: root.moduleName
        stateDir: root.stateDir
        reopenFlag: root.reopenFlag
        screenName: root.screenName
        onCloseRequested: root.close()
      }
    }
  }
}

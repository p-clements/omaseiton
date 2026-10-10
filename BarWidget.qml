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

  function open() {
    popoutSwitchClosing = false
    opened = true
  }
  function close() { opened = false }
  function closeForPopoutSwitch() { popoutSwitchClosing = true; close() }

  // Moving or toggling a widget rebuilds the whole bar, destroying this
  // instance mid-use. Panel leaves a fresh flag file before each change; the
  // replacement instance sees it and reopens straight away.
  Process {
    id: reopenCheck
    command: ["find", root.reopenFlag, "-newermt", "10 seconds ago"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text).trim() !== "") root.open()
        Quickshell.execDetached(["rm", "-f", root.reopenFlag])
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
    text: String.fromCodePoint(0xF0431)
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
        onCloseRequested: root.close()
      }
    }
  }
}

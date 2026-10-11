import QtQuick
import qs.Commons

// Single-line text field that deliberately contains no Qt text input.
// QQuickTextInput (and so QQC TextField) connects to QClipboard::dataChanged
// and reads the whole offered clipboard text to update `canPaste`, with no
// size limit or deadline. A hostile Wayland clipboard provider can stream
// data forever and stall or exhaust the shared shell, without any paste.
// This field only handles typed keys, so the clipboard is never touched
// (and paste is not supported on purpose).
FocusScope {
  id: root

  property color foreground: Color.foreground
  property string text: ""
  property string placeholderText: ""
  property int maximumLength: 64
  // The owner updates `text`; assigning it here would break the caller's binding.
  signal edited(string value)

  implicitHeight: Style.space(30)
  activeFocusOnTab: true

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Style.controlFill(root.activeFocus, false, root.foreground, Color.accent)
    border.width: 1
    border.color: root.activeFocus ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
  }

  Text {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    elide: Text.ElideLeft
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    color: root.text === "" ? Qt.darker(root.foreground, 1.6) : root.foreground
    text: root.text === "" ? root.placeholderText : root.text + (root.activeFocus ? "|" : "")
  }

  MouseArea {
    anchors.fill: parent
    onClicked: root.forceActiveFocus()
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Backspace) {
      root.edited(root.text.slice(0, -1))
      event.accepted = true
    } else if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
      // Leave shortcuts (including Ctrl+V) alone.
    } else if (event.text.length > 0 && event.text >= " " && event.text !== "\x7f") {
      if (root.text.length < root.maximumLength)
        root.edited(root.text + event.text.slice(0, root.maximumLength - root.text.length))
      event.accepted = true
    }
  }
}

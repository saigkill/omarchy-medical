import QtQuick
import qs.Commons
import qs.Ui

// Integer field with -/+ buttons and typed digits, built without any Qt text
// input or SpinBox. The host's NumberField wraps an editable TextInput, which
// reads the whole offered clipboard on every clipboard change (no size limit,
// no deadline), so a hostile clipboard owner could stall the shell. This one
// only handles key events and never touches the clipboard.
Column {
  id: root

  property string label: ""
  property int value: 0
  property int from: 0
  property int to: 100
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fieldWidth: Style.space(90)

  // The owner updates `value`; assigning it here would break its binding.
  signal modified(int value)

  spacing: Style.space(4)

  function _emit(v) {
    var n = Math.max(root.from, Math.min(root.to, v))
    if (n !== root.value) root.modified(n)
  }

  Text {
    visible: root.label !== ""
    text: root.label
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Row {
    spacing: Style.space(4)

    Button {
      text: "−"
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root._emit(root.value - 1)
    }

    FocusScope {
      id: box
      width: root.fieldWidth - Style.space(80)
      height: Style.space(30)
      activeFocusOnTab: true

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Style.controlFill(box.activeFocus, false, root.foreground, Color.accent)
        border.width: 1
        border.color: box.activeFocus ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
      }

      Text {
        anchors.centerIn: parent
        text: String(root.value)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        onClicked: box.forceActiveFocus()
      }

      Keys.onPressed: function(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        if (event.key === Qt.Key_Backspace) {
          root._emit(Math.floor(root.value / 10))
        } else if (event.key === Qt.Key_Up) {
          root._emit(root.value + 1)
        } else if (event.key === Qt.Key_Down) {
          root._emit(root.value - 1)
        } else if (event.text.length === 1 && event.text >= "0" && event.text <= "9") {
          root._emit(root.value * 10 + Number(event.text))
        } else {
          return
        }
        event.accepted = true
      }
    }

    Button {
      text: "+"
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root._emit(root.value + 1)
    }
  }
}

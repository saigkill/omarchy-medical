import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Management panel for the medication tracker: list, add/edit/remove,
// intake logging and stock adjustment. All data and mutations live on the
// host bar widget; this panel reads and calls through `hostWidget`.
Panel {
  id: root
  moduleName: "saigkill.meds"
  ipcTarget: "saigkill.meds"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property var meds: hostWidget ? hostWidget.medications : []
  readonly property var log: hostWidget ? hostWidget.intakeLog : []
  readonly property date now: hostWidget ? hostWidget.now : new Date()

  readonly property string dayKey: Model.keyForDate(now)
  readonly property var status: Model.statusView(meds, log, now)
  readonly property color warningColor: "#c9a227"

  readonly property color contentForeground: bar ? bar.barForeground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- editor state ------------------------------------------------
  property bool editing: false
  property bool isNew: false
  property string editId: ""
  property string editName: ""
  property string editDosage: ""
  property string editTimes: ""
  property int editMinStock: 0
  property int editCurrentStock: 0

  property string pendingDeleteId: ""
  property string pendingDeleteName: ""

  function open() {
    root.controller.show()
  }

  function close() {
    if (root.editing) root.editing = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // ---- editing -------------------------------------------------------
  function startAdd() {
    root.isNew = true
    root.editId = ""
    root.editName = ""
    root.editDosage = ""
    root.editTimes = ""
    root.editMinStock = 0
    root.editCurrentStock = 0
    root.editing = true
  }

  function startEdit(med) {
    root.isNew = false
    root.editId = String(med.id || "")
    root.editName = String(med.name || "")
    root.editDosage = String(med.dosage || "")
    root.editTimes = (med.times || []).join(", ")
    root.editMinStock = Math.max(0, Math.round(Number(med.minStock) || 0))
    root.editCurrentStock = Math.max(0, Math.round(Number(med.currentStock) || 0))
    root.editing = true
  }

  function saveEdit() {
    var name = String(root.editName).replace(/^\s+|\s+$/g, "")
    if (name === "" || !root.hostWidget) return
    var patch = {
      name: name,
      dosage: String(root.editDosage).replace(/^\s+|\s+$/g, ""),
      times: Model.parseTimesText(root.editTimes),
      minStock: root.editMinStock,
      currentStock: root.editCurrentStock
    }
    if (root.isNew) root.hostWidget.addMedication(patch)
    else root.hostWidget.updateMedication(root.editId, patch)
    root.editing = false
  }

  // ---- deletion --------------------------------------------------------
  function requestDelete(med) {
    root.pendingDeleteName = String(med.name || "")
    root.pendingDeleteId = String(med.id || "")
    root.confirmDelete.opened = true
  }

  function confirmDelete() {
    if (root.pendingDeleteId !== "" && root.hostWidget)
      root.hostWidget.removeMedication(root.pendingDeleteId)
    root.pendingDeleteId = ""
    root.confirmDelete.opened = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(listColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: !!(root.editing || root.confirmDelete.opened)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: listScroll
        anchors.fill: parent
        // Single-column layout, so the content is exactly as wide as the
        // viewport and never scrolls horizontally. Height comes from the
        // column itself: a hand-rolled sum of the children's implicitHeight
        // over-estimated and left dead space under the last row.
        contentWidth: width
        contentHeight: listColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: listColumn
          width: listScroll.width
          spacing: Style.space(8)

          // ---- header --------------------------------------------------
          Item {
            width: parent.width
            height: headerRow.height
            implicitHeight: headerRow.height

            Row {
              id: headerRow
              spacing: Style.space(8)

              PanelSectionHeader {
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                text: "MEDICATIONS" + (root.status.medicationCount > 0 ? "  " + root.status.medicationCount : "")
              }

              PanelActionButton {
                iconText: "\uf067"
                tooltipText: "Add medication"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.startAdd()
              }
            }
          }

          // ---- low-stock banner ------------------------------------------
          Rectangle {
            visible: root.status.hasLowStock
            width: parent.width
            height: visible ? lowRow.implicitHeight + Style.space(12) : 0
            implicitHeight: visible ? lowRow.implicitHeight + Style.space(12) : 0
            radius: Style.cornerRadius
            color: Qt.rgba(root.warningColor.r, root.warningColor.g, root.warningColor.b, 0.14)

            Row {
              id: lowRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf523"
                color: root.warningColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width - Style.space(40)
                anchors.verticalCenter: parent.verticalCenter
                text: root.lowStockSummary()
                color: root.warningColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          // ---- add/edit form --------------------------------------------
          Rectangle {
            visible: root.editing
            width: parent.width
            height: visible ? editColumn.implicitHeight + Style.space(14) : 0
            implicitHeight: visible ? editColumn.implicitHeight + Style.space(14) : 0
            radius: Style.cornerRadius
            color: Style.controlFill(false, false, root.contentForeground, Color.accent)

            Column {
              id: editColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              TextField {
                width: parent.width
                foreground: root.contentForeground
                text: root.editName
                placeholderText: root.isNew ? "Name (required)" : "Name"
                onTextChanged: root.editName = text
              }

              TextField {
                width: parent.width
                foreground: root.contentForeground
                text: root.editDosage
                placeholderText: "Dosage, e.g. 400mg"
                onTextChanged: root.editDosage = text
              }

              TextField {
                width: parent.width
                foreground: root.contentForeground
                text: root.editTimes
                placeholderText: "Times, e.g. 08:00, 20:00"
                onTextChanged: root.editTimes = text
              }

              Row {
                spacing: Style.space(12)

                NumberField {
                  label: "Stock"
                  fieldWidth: Style.space(90)
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  value: root.editCurrentStock
                  from: 0
                  to: 9999
                  onModified: function(amount) { root.editCurrentStock = amount }
                }

                NumberField {
                  label: "Min stock"
                  fieldWidth: Style.space(90)
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  value: root.editMinStock
                  from: 0
                  to: 9999
                  onModified: function(amount) { root.editMinStock = amount }
                }
              }

              Row {
                spacing: Style.space(10)

                Button {
                  text: "Save"
                  bordered: true
                  focusable: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.saveEdit()
                }

                Button {
                  text: "Cancel"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.editing = false
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.contentForeground
          }

          // ---- empty state ------------------------------------------------
          Text {
            visible: root.meds.length === 0
            width: parent.width
            text: "No medications yet. Use the + button to add one."
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- medication rows ---------------------------------------------
          Repeater {
            model: root.meds

            Item {
              required property var modelData
              width: parent.width
              height: row.implicitHeight
              implicitHeight: row.implicitHeight

              Row {
                id: row
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Column {
                  id: medInfo
                  width: Style.space(180)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.medSubline(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Column {
                  width: Style.space(50)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: Model.doseProgress(modelData, root.log, root.dayKey)
                    color: root.medProgressColor(modelData)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "taken"
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Column {
                  width: Style.space(62)
                  spacing: Style.space(2)

                  Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: root.stockDotColor(modelData)
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData.currentStock
                    color: root.stockTextColor(modelData)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "min " + modelData.minStock
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  spacing: Style.space(4)

                  PanelActionButton {
                    iconText: "\uf00c"
                    tooltipText: "Taken"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: if (root.hostWidget) root.hostWidget.logIntake(modelData.id)
                  }

                  PanelActionButton {
                    iconText: "\uf067"
                    tooltipText: "Add stock"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: if (root.hostWidget) root.hostWidget.adjustStock(modelData.id, 1)
                  }

                  PanelActionButton {
                    iconText: "\uf068"
                    tooltipText: "Remove stock"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: if (root.hostWidget) root.hostWidget.adjustStock(modelData.id, -1)
                  }

                  PanelActionButton {
                    iconText: "\uf044"
                    tooltipText: "Edit"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.startEdit(modelData)
                  }

                  PanelActionButton {
                    iconText: "\uf1f8"
                    tooltipText: "Delete"
                    foreground: Qt.darker(root.contentForeground, 1.3)
                    fontFamily: root.contentFontFamily
                    onClicked: root.requestDelete(modelData)
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- row helpers -------------------------------------------------------
  function medSubline(med) {
    var parts = []
    if (med.dosage) parts.push(med.dosage)
    if (med.times && med.times.length > 0) parts.push(med.times.join(" "))
    return parts.join("  ·  ")
  }

  function medProgressColor(med) {
    var planned = Model.doseTimes(med.times).length
    if (planned === 0) return Qt.darker(root.contentForeground, 1.7)
    var done = Model.dosesDone(root.log, med.id, root.dayKey)
    return done >= planned ? root.contentForeground : root.warningColor
  }

  function stockDotColor(med) {
    var s = Model.stockStatus(med)
    if (s === "empty") return Color.urgent
    if (s === "low") return root.warningColor
    return Qt.darker(root.contentForeground, 1.7)
  }

  function stockTextColor(med) {
    var s = Model.stockStatus(med)
    if (s === "empty") return Color.urgent
    if (s === "low") return root.warningColor
    return root.contentForeground
  }

  function lowStockSummary() {
    var names = []
    for (var i = 0; i < root.status.lowStock.length; i++) {
      var med = root.status.lowStock[i]
      var s = Model.stockStatus(med)
      names.push((s === "empty" ? "empty: " : "low: ") + med.name + " (" + med.currentStock + "/" + med.minStock + ")")
    }
    return "Stock " + names.join(", ")
  }

  ConfirmDialog {
    id: confirmDelete
    anchors.fill: parent
    message: "Delete " + root.pendingDeleteName + "? Intake history is removed too."
    confirmText: "Delete"
    foreground: root.contentForeground
    fontFamily: root.contentFontFamily
    onConfirmed: root.confirmDelete()
    onCanceled: {
      root.pendingDeleteId = ""
      root.confirmDelete.opened = false
    }
  }
}
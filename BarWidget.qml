import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Medication tracker bar widget: a pill icon whose color reflects dose and
// stock state, plus the host for the management panel. Owns the data file
// (load/save) and the reminder + stock-warning timers; the panel mutates
// through the functions below.
BarWidget {
  id: root
  moduleName: "saigkill.meds"

  // State must NOT live inside the plugin directory: Quickshell watches that
  // folder and reloads the plugin on any write, which drops an open panel.
  readonly property string dataFile: Quickshell.env("HOME")
    + "/.local/state/omarchy-meds/data.json"

  property date now: new Date()
  property var medications: []
  property var intakeLog: []

  // Reminder and stock warnings fire once per (slot|day) and per (med|day).
  // Both maps store the timestamp of the notification the shell actually
  // delivered, so a send that never arrived stays eligible and is retried.
  property var remindedKeys: ({})
  property var stockNotifiedKeys: ({})

  // A dose that is never logged nags again after this long.
  readonly property int reminderRepeatMs: 60 * 60 * 1000

  // The notification currently being handed to omarchy-notification-send.
  property var inflight: null
  property var notifyQueue: []

  readonly property string dayKey: Model.keyForDate(now)
  readonly property var view: Model.statusView(medications, intakeLog, now)

  readonly property bool hasDue: view.hasDue
  readonly property bool hasLowStock: view.hasLowStock
  readonly property bool isIdle: medications.length === 0

  // ---- state color for the bar icon
  readonly property color warningColor: "#c9a227"
  readonly property color stateColor: hasDue
    ? Color.urgent
    : (hasLowStock ? warningColor : (bar ? bar.barForeground : Color.foreground))
  readonly property bool urgent: hasDue

  readonly property string tooltipText: isIdle
    ? "Medication tracker: no medications configured"
    : (messageDetail(view))

  function messageDetail(v) {
    var lines = []
    if (v.hasDue) lines.push("Overdue: " + v.dueLabel)
    else if (v.nextLabel) lines.push("Next: " + v.nextLabel)
    if (v.lowStock.length > 0) {
      for (var i = 0; i < v.lowStock.length; i++) {
        var med = v.lowStock[i]
        var st = Model.stockStatus(med)
        lines.push((st === "empty" ? "Stock empty: " : "Low stock: ")
          + med.name + " (" + med.currentStock + " left, min " + med.minStock + ")")
      }
    }
    return lines.length > 0 ? lines.join("\n") : "All doses up to date"
  }

  // ---- persistence -------------------------------------------------
  function loadData() {
    loadProc.command = ["sh", "-c", 'cat "$1" 2>/dev/null || true', "sh", root.dataFile]
    loadProc.running = true
  }

  function applyData(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "")) } catch (error) { parsed = null }
    var data = Model.decode(parsed)
    root.medications = data.medications
    root.intakeLog = data.log
    // Write the repaired times back so the life chart plugin sees them too.
    if (data.repaired) root.saveData()
    root.refreshNow()
  }

  function saveData() {
    var data = Model.trimLog({ medications: root.medications, log: root.intakeLog }, 30)
    var json = JSON.stringify(data)
    saveProc.command = ["sh", "-c",
      'mkdir -p "$(dirname "$2")" && printf %s "$1" > "$2"',
      "sh", json, root.dataFile]
    saveProc.running = true
  }

  // ---- mutation API for the panel ------------------------------------
  function addMedication(fields) {
    if (!fields || !String(fields.name || "").trim()) return false
    var med = {
      id: Model.newId(),
      name: String(fields.name).trim(),
      dosage: String(fields.dosage || "").trim(),
      times: Model.storedTimes(fields.times),
      currentStock: Math.max(0, Math.round(Number(fields.currentStock) || 0)),
      minStock: Math.max(0, Math.round(Number(fields.minStock) || 0)),
      enabled: fields.enabled !== false
    }
    root.medications = root.medications.concat([med])
    root.saveData()
    root.refreshNow()
    return med
  }

  function updateMedication(id, patch) {
    var next = root.medications.map(function(med) {
      if (med.id !== id) return med
      var merged = {}
      for (var key in med) merged[key] = med[key]
      for (var p in patch) merged[p] = patch[p]
      if ("times" in patch) merged.times = Model.storedTimes(patch.times)
      merged.currentStock = Math.max(0, Math.round(Number(merged.currentStock) || 0))
      merged.minStock = Math.max(0, Math.round(Number(merged.minStock) || 0))
      return merged
    })
    root.medications = next
    root.saveData()
    root.refreshNow()
  }

  function removeMedication(id) {
    root.medications = root.medications.filter(function(med) { return med.id !== id })
    root.intakeLog = root.intakeLog.filter(function(entry) { return entry.medicationId !== id })
    root.saveData()
    root.refreshNow()
  }

  function adjustStock(id, delta) {
    root.medications = root.medications.map(function(med) {
      if (med.id !== id) return med
      var stock = Math.round(Number(med.currentStock) || 0) + Math.round(Number(delta) || 0)
      med.currentStock = Math.max(0, stock)
      return med
    })
    root.saveData()
    root.refreshNow()
  }

  function logIntake(id) {
    root.intakeLog = root.intakeLog.concat([{ medicationId: id, timestamp: new Date().toISOString() }])
    root.adjustStock(id, -1)
    // The dose is now logged, so its slot is no longer due; the reminder
    // keys for the other (untaken) slots stay untouched.
    root.saveData()
    root.refreshNow()
  }

  function slotKey(med, key, timeText) {
    return Model.slotKey(med, key, timeText)
  }

  // ---- periodic checks ----------------------------------------------
  function refreshNow() {
    root.now = new Date()
  }

  function checkStatus() {
    root.refreshNow()
    fireDueReminders()
    fireStockWarnings()
  }

  // Every dose whose time has passed and that is not logged shows up here,
  // not just the ones that came due while the session was running: booting at
  // 09:00 with an 08:00 dose still unlogged reports it like any other miss.
  // Missed doses are batched into a single toast instead of one per dose.
  function fireDueReminders() {
    if (root.medications.length === 0) return
    var pending = Model.pendingSlots(root.medications, root.intakeLog, root.now)
    var plan = Model.dueNotifications(pending, root.dayKey, root.remindedKeys,
      root.now.getTime(), root.reminderRepeatMs)
    if (plan.entries.length === 0) return

    var labels = []
    var keys = []
    for (var i = 0; i < plan.entries.length; i++) {
      labels.push(Model.slotLabel(plan.entries[i].slot))
      keys.push(plan.entries[i].key)
    }
    var title = plan.entries.length === 1
      ? (plan.hasRepeat ? "Medication still due" : "Medication due")
      : plan.entries.length + (plan.hasRepeat ? " doses still due" : " doses due")
    sendNotification({
      store: "reminder",
      keys: keys,
      title: title,
      body: labels.join(",  "),
      urgency: "critical",
      replaceId: batchId(keys)
    })
  }

  // Same batching as the dose reminders, and the same retry-on-success, so a
  // low-stock warning is not lost either while the shell is starting.
  function fireStockWarnings() {
    var meds = root.medications
    var labels = []
    var keys = []
    var anyEmpty = false
    var nowMs = root.now.getTime()
    for (var i = 0; i < meds.length; i++) {
      var med = meds[i]
      var status = Model.stockStatus(med)
      if (status === "ok") continue
      var key = med.id + "@" + root.dayKey + ":" + status
      var last = root.stockNotifiedKeys[key]
      if (last !== undefined && last !== null && nowMs - last < root.reminderRepeatMs) continue
      keys.push(key)
      labels.push(med.name + ": " + med.currentStock + " left, minimum " + med.minStock)
      if (status === "empty") anyEmpty = true
    }
    if (keys.length === 0) return
    var title = anyEmpty ? "Medication stock empty" : "Medication stock low"
    if (keys.length > 1) title = title + " (" + keys.length + ")"
    sendNotification({
      store: "stock",
      keys: keys,
      title: title,
      body: labels.join(",  "),
      urgency: "normal",
      replaceId: batchId(keys)
    })
  }

  // One Process serves every notification. A send is only recorded as done
  // once the process exits successfully, because the shell owns
  // org.freedesktop.Notifications itself and rejects notifications for the
  // first seconds after start — a reminder fired there would be lost for good.
  // A check can produce two notifications (doses and stock), so they queue
  // instead of the second one silently losing the race for the Process.
  function sendNotification(job) {
    root.notifyQueue = root.notifyQueue.concat([job])
    pumpNotifyQueue()
  }

  function pumpNotifyQueue() {
    if (root.notifyQueue.length === 0 || notifyProc.running) return
    root.inflight = root.notifyQueue[0]
    notifyProc.command = ["omarchy-notification-send", "-g", "\uf484", "-u", root.inflight.urgency,
      "-r", String(root.inflight.replaceId), root.inflight.title, root.inflight.body]
    notifyProc.running = true
  }

  // Each bar runs its own widget, so the same reminder is sent once per bar.
  // A replace id derived from the slot keys makes the shell update a single
  // toast in place instead of stacking one identical toast per bar.
  function batchId(keys) {
    var text = root.dayKey
    for (var i = 0; i < keys.length; i++) text += "|" + keys[i]
    var hash = 0
    for (var j = 0; j < text.length; j++) hash = (hash * 31 + text.charCodeAt(j)) % 1000000007
    return 1000 + (hash % 900000)
  }

  // ---- panel lifecycle (shape contract for shell summon/hide/toggle) ---
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: loadData()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    // Deliberately not triggeredOnStart: at t=0 the shell is still bringing
    // up its own notification service, so a send there is rejected. The
    // first check at 30s lands after that, and a failed send is retried by
    // the next tick regardless.
    triggeredOnStart: false
    onTriggered: root.checkStatus()
  }

  IpcHandler {
    target: "saigkill.meds"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.checkStatus() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf484"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: root.urgent
    enabled: true
    foreground: root.stateColor
    tooltipText: root.tooltipText

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  // ---- io -----------------------------------------------------------
  Process {
    id: loadProc
    stdout: StdioCollector {
      id: loadOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.applyData(loadOut.text)
    }
  }

  Process {
    id: saveProc
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("saigkill.meds: failed to save data file")
    }
  }

  Process {
    id: notifyProc
    onExited: function(exitCode) {
      var job = root.inflight
      root.inflight = null
      root.notifyQueue = root.notifyQueue.slice(1)
      if (job) {
        if (exitCode !== 0) {
          // Nothing is recorded, so the next check simply tries again.
          console.warn("saigkill.meds: notification not delivered (exit "
            + exitCode + "), retrying on next check")
        } else {
          var target = job.store === "stock" ? root.stockNotifiedKeys : root.remindedKeys
          var next = {}
          for (var known in target) next[known] = target[known]
          var stamp = Date.now()
          for (var i = 0; i < job.keys.length; i++) next[job.keys[i]] = stamp
          if (job.store === "stock") root.stockNotifiedKeys = next
          else root.remindedKeys = next
        }
      }
      pumpNotifyQueue()
    }
  }
}
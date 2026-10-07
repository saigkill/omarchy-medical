// Pure medication logic for the meds bar widget and panel. Qt-free so it can
// be unit tested under node; the QML owns file IO and UI.

var MS_PER_DAY = 86400000

function newId() {
  return "m" + Date.now().toString(36) + Math.floor(Math.random() * 0xffffff).toString(36).padStart(2, "0")
}

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

function keyForDate(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

// "HH:mm" -> minutes since midnight, or null when malformed.
function parseTimeMinutes(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (!/^([01]?\d|2[0-3]):[0-5]\d$/.test(text)) return null
  var parts = text.split(":")
  return Number(parts[0]) * 60 + Number(parts[1])
}

function formatMinutes(minutes) {
  var value = Number(minutes)
  if (!isFinite(value)) return ""
  value = Math.max(0, Math.min(23 * 60 + 59, Math.round(value)))
  return pad2(Math.floor(value / 60)) + ":" + pad2(value % 60)
}

function minutesOfDay(date) {
  return date.getHours() * 60 + date.getMinutes()
}

// Minutes since midnight for each valid "HH:mm" entry: sorted ascending,
// deduped. For the slot logic; use storedTimes() for what goes on disk.
function doseTimes(value) {
  var raw = Array.isArray(value) ? value : []
  var seen = {}
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var mins = parseTimeMinutes(raw[i])
    if (mins === null || mins in seen) continue
    seen[mins] = true
    out.push(mins)
  }
  out.sort(function(a, b) { return a - b })
  return out
}

// The on-disk form of `times`: the doseTimes() set as "HH:mm" strings. The
// life chart plugin reads these strings, and parseTimeMinutes() rejects bare
// numbers, so storing minutes would silently drop every slot on reload.
function storedTimes(value) {
  return doseTimes(value).map(formatMinutes)
}

// "08:00, 20:00" -> validated "HH:mm" entries; junk is dropped.
function parseTimesText(text) {
  var parts = String(text || "").split(",")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var mins = parseTimeMinutes(parts[i])
    if (mins !== null) out.push(formatMinutes(mins))
  }
  return out
}

// Stock gets a status independent of the intake schedule.
function stockStatus(med) {
  var stock = Math.max(0, Math.round(Number(med.currentStock) || 0))
  var min = Math.max(0, Math.round(Number(med.minStock) || 0))
  if (stock <= 0) return "empty"
  if (stock <= min) return "low"
  return "ok"
}

// A log entry within this many minutes of a slot belongs to that slot.
var SLOT_TOLERANCE_MINUTES = 45

// Which of a day's log entries covers which slot: { minutes: timestamp }.
// Each entry covers at most one slot, so one tick never marks both the
// morning and the evening dose. Three passes, in order:
//   1. entries within SLOT_TOLERANCE_MINUTES of a slot, closest pairs first;
//   2. a late intake covers the latest still-open slot before it (a dose
//      ticked at 15:37 is the missed 08:00 dose, which must stop nagging);
//   3. an early intake covers the next slot after it, if that one is still
//      open and the entry lies closer to it than to the slot before (a dose
//      taken at 06:30 for 08:00 must not trigger the 08:00 reminder).
// Computed from the log every time, so no slot is stored in the data file.
function slotAssignment(med, log, dateKey) {
  var slots = doseTimes(med.times)
  var entries = []
  var all = log || []
  for (var i = 0; i < all.length; i++) {
    if (all[i].medicationId !== med.id) continue
    var date = new Date(all[i].timestamp)
    if (isNaN(date.getTime()) || keyForDate(date) !== dateKey) continue
    entries.push({ minutes: minutesOfDay(date), timestamp: all[i].timestamp, used: false })
  }
  entries.sort(function(a, b) { return a.minutes - b.minutes })

  var taken = {}
  var pairs = []
  for (var s = 0; s < slots.length; s++) {
    for (var e = 0; e < entries.length; e++) {
      var distance = Math.abs(entries[e].minutes - slots[s])
      if (distance <= SLOT_TOLERANCE_MINUTES) pairs.push({ slot: slots[s], entry: entries[e], distance: distance })
    }
  }
  pairs.sort(function(a, b) { return a.distance - b.distance })
  for (var p = 0; p < pairs.length; p++) {
    if (pairs[p].entry.used || pairs[p].slot in taken) continue
    taken[pairs[p].slot] = pairs[p].entry.timestamp
    pairs[p].entry.used = true
  }

  for (var l = 0; l < entries.length; l++) {
    if (entries[l].used) continue
    for (var before = slots.length - 1; before >= 0; before--) {
      if (slots[before] > entries[l].minutes || slots[before] in taken) continue
      taken[slots[before]] = entries[l].timestamp
      entries[l].used = true
      break
    }
  }

  // Only the very next slot, and only from halfway after the previous one:
  // a double tick at 08:20 must not silence the 20:00 reminder.
  for (var r = 0; r < entries.length; r++) {
    if (entries[r].used) continue
    for (var next = 0; next < slots.length && slots[next] <= entries[r].minutes; next++) {}
    if (next >= slots.length || slots[next] in taken) continue
    if (next > 0 && entries[r].minutes < (slots[next - 1] + slots[next]) / 2) continue
    taken[slots[next]] = entries[r].timestamp
    entries[r].used = true
  }
  return taken
}

function takenDateFor(med, log, dateKey, timeMinutes) {
  var taken = slotAssignment(med, log, dateKey)
  return timeMinutes in taken ? taken[timeMinutes] : null
}

function slotTaken(med, log, dateKey, timeMinutes) {
  return takenDateFor(med, log, dateKey, timeMinutes) !== null
}

// True when the slot has arrived (time passed) and is not yet logged.
function slotDue(med, log, now, key, timeMinutes) {
  if (!med.enabled) return false
  if (slotTaken(med, log, key, timeMinutes)) return false
  return minutesOfDay(now) >= timeMinutes
}

// Each pending slot for today: already arrived, still unlogged.
function pendingSlots(meds, log, now) {
  var key = keyForDate(now)
  var out = []
  for (var i = 0; i < (meds || []).length; i++) {
    var med = meds[i]
    var times = doseTimes(med.times)
    for (var t = 0; t < times.length; t++) {
      var mins = times[t]
      var taken = slotTaken(med, log, key, mins)
      if (taken) continue
      var arrived = minutesOfDay(now) >= mins
      out.push({
        med: med,
        timeText: formatMinutes(mins),
        taken: taken,
        arrived: arrived,
        due: arrived && med.enabled
      })
    }
  }
  return out
}

// Stable identity of one dose slot of one medication on one day.
function slotKey(med, dateKey, timeText) {
  return med.id + "@" + dateKey + ":" + timeText
}

// "Metoprolol 25 mg (07:30)" — the label used in reminder notifications.
function slotLabel(slot) {
  var parts = [slot.med.name]
  if (slot.med.dosage) parts.push(slot.med.dosage)
  parts.push("(" + slot.timeText + ")")
  return parts.join(" ")
}

// Which due, still-unlogged slots deserve a notification right now.
//
// `lastNotified` maps a slot key to the timestamp of the notification the
// shell actually delivered. A slot missing from that map is always due again,
// which is what catches doses whose time passed while the machine was off —
// and doses whose send was lost because the shell was still starting up.
// Everything else only repeats once `repeatMs` has passed, so a dose that is
// never logged keeps nagging but not on every check.
function dueNotifications(slots, dateKey, lastNotified, nowMs, repeatMs) {
  var entries = []
  var hasRepeat = false
  var seen = lastNotified || {}
  for (var i = 0; i < (slots || []).length; i++) {
    var slot = slots[i]
    if (!slot.due) continue
    var key = slotKey(slot.med, dateKey, slot.timeText)
    var last = seen[key]
    if (last === undefined || last === null) {
      entries.push({ slot: slot, key: key, repeat: false })
    } else if (nowMs - last >= repeatMs) {
      entries.push({ slot: slot, key: key, repeat: true })
      hasRepeat = true
    }
  }
  return { entries: entries, hasRepeat: hasRepeat }
}

// The single most-urgent pending item, or null. Prefers a due (arrived) dose
// over the next upcoming one.
function mostUrgent(pending) {
  var due = null
  var next = null
  for (var i = 0; i < (pending || []).length; i++) {
    var slot = pending[i]
    if (!slot.med.enabled) continue
    if (slot.due && (!due || slot.timeText < due.timeText)) due = slot
    if (!slot.due && (!next || slot.timeText < next.timeText)) next = slot
  }
  return due || next || null
}

// Bar label helper: live time of the most urgent dose, or "".
function nextIntakeLabel(meds, log, now) {
  var urgent = mostUrgent(pendingSlots(meds, log, now))
  return urgent ? urgent.timeText : ""
}

function medicationCount(meds) {
  return (meds || []).length
}

function dosesDone(log, medId, dateKey) {
  var count = 0
  var entries = log || []
  for (var i = 0; i < entries.length; i++)
    if (entries[i].medicationId === medId && keyForDate(new Date(entries[i].timestamp)) === dateKey) count++
  return count
}

// "2/3" dosing progress; "" when a medication has no times.
function doseProgress(med, log, dateKey) {
  var done = dosesDone(log, med.id, dateKey)
  var planned = doseTimes(med.times).length
  return planned > 0 ? done + "/" + planned : ""
}

// Friendly status summary for the tooltip.
function statusLine(meds, log, now) {
  var urgent = mostUrgent(pendingSlots(meds, log, now))
  if (!urgent) return "No medications configured"
  var state = urgent.due ? "Overdue" : "Next"
  return state + ": " + urgent.med.name + " " + urgent.timeText
}

// Everything the bar and panel need to render state in one pass.
function statusView(meds, log, now) {
  var pending = pendingSlots(meds, log, now)
  var urgent = mostUrgent(pending)
  var low = []
  for (var i = 0; i < (meds || []).length; i++) {
    if (stockStatus(meds[i]) !== "ok") low.push(meds[i])
  }
  return {
    medicationCount: (meds || []).length,
    hasDue: urgent ? urgent.due : false,
    dueLabel: urgent && urgent.due ? urgent.med.name + " " + urgent.timeText : "",
    nextLabel: urgent ? urgent.med.name + " " + urgent.timeText : "",
    lowStock: low,
    hasLowStock: low.length > 0
  }
}

function emptyData() {
  return { medications: [], log: [] }
}

// Version 1.0.0 stored `times` as minutes since midnight ([480, 1200]).
// Those entries match no slot, so the medication got no reminders at all;
// convert them back to "HH:mm". `repaired` tells the caller to save.
function repairTimes(med) {
  var raw = med && Array.isArray(med.times) ? med.times : null
  if (!raw || !raw.some(function(t) { return typeof t === "number" })) return null
  var fixed = {}
  for (var key in med) fixed[key] = med[key]
  fixed.times = storedTimes(raw.map(function(t) {
    return typeof t === "number" && t >= 0 && t < 24 * 60 ? formatMinutes(t) : t
  }))
  return fixed
}

function decode(data) {
  if (!data || typeof data !== "object") return emptyData()
  var repaired = false
  var meds = (Array.isArray(data.medications) ? data.medications : []).map(function(med) {
    var fixed = repairTimes(med)
    if (!fixed) return med
    repaired = true
    return fixed
  })
  return {
    medications: meds,
    log: Array.isArray(data.log) ? data.log : [],
    repaired: repaired
  }
}

// Drop log entries older than `days` so the file stays lean.
function trimLog(data, days) {
  var cutoff = Date.now() - Math.max(1, Number(days) || 30) * MS_PER_DAY
  return {
    medications: (data.medications || []).slice(),
    log: (data.log || []).filter(function(entry) {
      var time = new Date(entry.timestamp).getTime()
      return isFinite(time) && time > cutoff
    })
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    newId: newId,
    keyForDate: keyForDate,
    parseTimeMinutes: parseTimeMinutes,
    formatMinutes: formatMinutes,
    minutesOfDay: minutesOfDay,
    doseTimes: doseTimes,
    storedTimes: storedTimes,
    parseTimesText: parseTimesText,
    stockStatus: stockStatus,
    slotAssignment: slotAssignment,
    takenDateFor: takenDateFor,
    slotTaken: slotTaken,
    slotDue: slotDue,
    pendingSlots: pendingSlots,
    mostUrgent: mostUrgent,
    nextIntakeLabel: nextIntakeLabel,
    medicationCount: medicationCount,
    dosesDone: dosesDone,
    doseProgress: doseProgress,
    statusLine: statusLine,
    statusView: statusView,
    emptyData: emptyData,
    decode: decode,
    trimLog: trimLog
  }
}
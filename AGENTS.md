# AGENTS.md

Guidance for AI agents working in this repository. The README documents *what*
the plugin does; this file records *how* to change it without breaking it.

## What this is

An Omarchy shell plugin (Quickshell/QML), id `saigkill.meds`, that tracks
medications, dose times and stock, and sends reminder notifications. It is a
single bar widget with a panel. There is no helper process and no network.

| File | Role |
|---|---|
| `manifest.json` | Plugin id, kind (`bar-widget`), entry point |
| `BarWidget.qml` | Owns all state: data file IO, mutation API, the 30 s check timer, notifications, IPC |
| `Panel.qml` | UI only. Reads and mutates through `hostWidget`; holds editor state, nothing persistent |
| `Model.js` | Pure date/dose/stock logic. Qt-free so it can run under node |

## The one rule that matters most

**A reminder must never be silently lost.** This is a medication tracker; a
missed notification can mean a missed dose. That is why:

- a slot is recorded in `remindedKeys` / `stockNotifiedKeys` only after
  `omarchy-notification-send` exits 0. The shell rejects notifications for its
  first seconds after start, so recording on *send* would drop them for good;
- the timer is deliberately not `triggeredOnStart` (see the comment there);
- `Model.dueNotifications()` treats a slot missing from `lastNotified` as due,
  which also catches doses whose time passed while the machine was off;
- notifications go through one queue (`notifyQueue`) so a dose reminder and a
  stock warning from the same check cannot race for the `Process`.

Keep all four properties when changing anything in that path.

## The user's data

`~/.local/state/omarchy-meds/data.json` holds the user's real medication data.
Do not edit, reset or "clean up" that file, and do not log or mark doses in the
running panel to test something. Test with a copy, or point `dataFile` at a
scratch path temporarily and put it back.

Health data must never appear in process arguments (world-readable via
`/proc`): `saveData` pipes the JSON over stdin and notifications carry no
medication details. The file and its directory stay private (`0600`/`0700`).

The life chart plugin (`saigkill.lifechart`, `../omarchy-lifechart`) reads
this file (read only) to suggest "medication taken" for a day and to list the
current medications in its PDF report. It relies on
`medications[].id/name/dosage/times/enabled` and `log[].medicationId/timestamp`.
When you change that format, update `medicationSuggestion()` in
`../omarchy-lifechart/Model.js` and `load_medications()` in
`../omarchy-lifechart/lifechart_report.py` too.

The file lives outside the plugin directory on purpose: Quickshell watches the
plugin folder and reloads the plugin on any write there, which closes an open
panel. Never move state into the plugin directory.

## Dose logic facts that are easy to get wrong

- **A slot counts as taken** when `slotAssignment()` gives it one of that
  day's log entries for the medication. Each entry covers at most one slot,
  assigned in three passes: (1) within `SLOT_TOLERANCE_MINUTES` (45) of a
  slot, closest pairs first; (2) a late intake covers the latest still-open
  slot before it (ticking at 15:37 covers a missed 08:00); (3) an early
  intake covers the very next slot, if still open and the entry is past the
  midpoint from the previous slot (a double tick at 08:20 must not cover
  20:00). The assignment is recomputed from the log; nothing is stored, so
  the data format and the life chart plugin are unaffected.
- **`dosesDone()` / `doseProgress()` count every entry of the day**, regardless
  of slot. A dose logged at 12:00 for 08:00/20:00 shows "1/2" in the panel but
  leaves both slots untaken. Keep that difference in mind when changing either.
- **Days are local calendar days** (`keyForDate`). There is no handling for
  slots near midnight or for time zone changes; a 23:50 dose logged at 00:10
  lands on the next day.
- **Times are normalized** by `doseTimes()` (sorted, deduped, minutes) and
  stored as `"HH:mm"` strings. Malformed input is dropped, not rejected.
- **`logIntake()` decrements stock by one.** Stock is clamped at 0 everywhere.
- **Each bar runs its own widget instance.** With several monitors the same
  reminder is sent once per bar; `batchId()` derives a stable replace id so
  the toasts merge into one. Do not replace it with a random id.

## Editing Model.js

Pure functions only: no Qt, no IO, no `Date.now()` where a `now` argument can
be passed instead. `module.exports` at the bottom is for node; it currently
leaves out `slotKey`, `slotLabel` and `dueNotifications`. Add
any function you want to test there.

There is no test suite yet. Until there is, check logic changes under node:

```sh
node -e '
const M = require("./Model.js")
const meds = [{ id: "a", name: "Test", times: ["08:00", "20:00"], currentStock: 3, minStock: 5, enabled: true }]
console.log(M.statusView(meds, [], new Date(2026, 0, 1, 9, 0)))'
```

## Editing the QML

**Count the braces after every insertion.** A stray `}` closes the enclosing
`Column`; Quickshell reports one `Syntax error` and the panel opens empty.

```sh
python3 - <<'EOF'
import re
for f in ('BarWidget.qml', 'Panel.qml'):
    depth = 0
    for l in open(f, encoding='utf-8').read().split('\n'):
        s = re.sub(r'"(\\.|[^"\\])*"', '""', l)
        s = re.sub(r'//.*', '', s)
        for c in s:
            depth += (c == '{') - (c == '}')
    print(f, depth)  # must be 0
EOF
```

- `qmllint` is not a syntax check here: `qs.*` imports give false positives.
- An invisible item still reports `implicitHeight` to a `Column`; use
  `height: visible ? implicitHeight : 0` (as the banner and form already do).
- `medications` and `intakeLog` must be **replaced**, never mutated in place,
  or bindings (`view`, the panel's `Repeater`) will not update. Use
  `concat` / `map` / `filter` and assign the result.
- Every mutation in `BarWidget.qml` ends with `saveData()` and `refreshNow()`.
  Keep that pattern for new ones.
- A QML `id` and a function or property of the same name on `root` collide;
  `root.<name>` resolves to the property/function, not the item. Give ids
  distinct names.
- `KeyboardPanel` only accepts visual items as direct children; keep `Process`
  objects at the top level of `BarWidget.qml`.
- File IO goes through `sh -c` with the values as positional arguments
  (`"$1"`, `"$2"`), never interpolated into the script string.

## Deploying to test

`~/.config/omarchy/plugins/saigkill.meds` is a symlink to this directory, so
saved changes go straight into the running shell.

```sh
omarchy restart shell
journalctl --user --since "-1m" | grep -i meds
```

Use a full restart: QML keeps components it has already compiled, and
`rescanPlugins` does not replace them. After a restart started from an agent,
check that `quickshell` is running again; if not, start it with
`hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")'`.

IPC for quick checks: `omarchy-shell saigkill.meds toggle`, `... refresh`.

## Conventions

- English in code, comments and the README; German in conversation.
- No dependencies beyond Qt/QML, Quickshell and the Omarchy shell's `qs.*`
  modules. `omarchy-notification-send` is the only external command.
- UI strings are English and hard-coded; there is no localization layer.
- Match the surrounding comment density: explain *why*.
- Bump `version` in `manifest.json` for user-visible changes.

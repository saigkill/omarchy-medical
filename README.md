# Medication tracker (saigkill.meds)

Track medications, their daily intake times, and stock levels in the Omarchy
Quattro bar.

![Preview](https://github.com/saigkill/omarchy-medical/blob/master/preview.png?raw=true)

## Features

- **Bar widget** — a pill icon whose color reflects the current state:
  - Red: a dose is due (overdue)
  - Amber: at least one medication is below its configured minimum stock
  - Neutral: everything is on schedule
  The tooltip names the next/overdue dose and any low-stock medications.
- **Reminders** — when a dose time arrives and the dose has not been logged,
  a desktop notification fires (`omarchy-notification-send`, once per slot
  per day).
- **Stock monitoring** — each medication has a current stock and a minimum
  stock. Reaching the minimum (or zero) raises a notification.
- **Panel** — click the pill to open the management panel:
  - List medications with name, dosage, intake times, dose progress ("1/2"),
    and stock state.
  - Add / edit / delete medications (delete asks for confirmation).
  - Log an intake (auto-decrements stock by one), or adjust stock directly
    with + / −.

## Data model

Each medication has:

```json
{
  "id": "string",
  "name": "Ibuprofen",
  "dosage": "400mg",
  "times": ["08:00", "20:00"],
  "currentStock": 12,
  "minStock": 5,
  "enabled": true
}
```

Intake log entries record `{ "medicationId": "...", "timestamp": "ISO" }`.
A dose counts as "taken" for a slot when an entry exists within 45 minutes of
the scheduled time, so logging a few minutes late still marks the slot done.

Data is stored in `~/.local/state/omarchy-meds/data.json` (deliberately outside
the plugin directory — writing there makes Quickshell reload the plugin).
Log entries older than 30 days are dropped on save.

## Install

```sh
omarchy plugin add https://github.com/saigkill/omarchy-medical.git --enable
```

## Configure

Move the widget in the bar like any other:

```sh
omarchy bar move saigkill.meds --section right
```

## Notes on notifications

Due-dose reminders are sent instantly with `omarchy-notification-send` (the
same engine `omarchy reminder` fires when a countdown elapses). The
`omarchy reminder` CLI itself cannot fire at "now": it rejects `0` minutes
and is a countdown primitive (`systemd-run --on-active`).

Notification text is generic ("Medication due", "Open the medication panel for
details"): it travels as a process argument, which other local users can read
through `/proc`, so it never contains medication names, doses or stock numbers.
`data.json` is written privately (directory `0700`, file `0600`).

## Remove

```sh
omarchy plugin remove saigkill.meds
```
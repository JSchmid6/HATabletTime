# HATabletTime – Architecture

## Overview

HATabletTime is a Flutter Android app. It acts as a **kiosk-style booking terminal** for a single child.
It communicates exclusively with the **Home Assistant REST and WebSocket APIs** — there is no custom backend.

```
Tablet (Flutter App)
  │
  │  REST: GET /api/states/{entity}          – read balance, limit, usage
  │  REST: POST /api/services/script/turn_on – call booking script
  │  WS:   /api/websocket                   – setup wizard only
  ▼
Home Assistant
  ├── input_number.zeitkonto_{child}         – balance (minutes)
  ├── number.familylink_{id}_today_limit     – Family Link daily limit (HAFamilyLink)
  ├── sensor.familylink_{id}_screen_time     – screen time used today (HAFamilyLink)
  └── script.zeitkonto_aufladen             – update balance (see below)
```

---

## Flutter Project Structure

```
lib/
  main.dart                     Entry point; portrait lock; immersive mode
  app.dart                      MaterialApp + startup router (wizard vs. home)
  models/
    account_config.dart         Typed DTO stored in EncryptedSharedPreferences
  services/
    ha_client.dart              REST client + WebSocket session (WsSession)
    entity_discovery.dart       Discovers children/devices from HA entity states
    secure_storage.dart         FlutterSecureStorage wrapper (Android Encrypted SP)
  screens/
    setup_wizard.dart           4-step first-run wizard
    home_screen.dart            Balance display + booking buttons
```

---

## Startup Flow

```
main()
  └─ HaTabletTimeApp
       └─ _StartupRouter
            ├─ SecureStorage.loadConfig() == null  →  SetupWizard
            └─ config loaded                       →  HomeScreen
```

---

## Setup Wizard (4 steps)

| Step | What happens |
|------|--------------|
| 1 – HA URL | User types URL; app does a GET /api/states to verify reachability |
| 2 – Admin token | User pastes long-lived admin token; `EntityDiscovery` loads children |
| 3 – Select child | Dropdown of discovered children + their devices |
| 4 – Provision | WS: create restricted user + long-lived token; save `AccountConfig`; discard admin token |

After step 4 the admin token is **never persisted**.
Only the restricted child token is stored (encrypted).

> **TODO (Phase 3):** The HA WebSocket API only allows a user to create their *own* long-lived token.
> Step 4 currently falls back to the admin token as a placeholder.
> The proper solution is to log in as the new user through the HA auth flow and then create the token.

---

## Home Screen

- Polls three entities every 30 s: balance, today-limit, screen-time sensor
- Booking buttons: **+15 / +30 / +45 / +60 min** (buy) and **−15 / −30 min** (return)
- Button enabled conditions:
  - Buy:    `balance >= amount  AND  (todayLimit + amount) <= 720`
  - Return: `(todayLimit − amount) >= usedToday`
- Confirmation dialog before every booking (shows balance after action)
- Calls `script.zeitkonto_aufladen` via `POST /api/services/script/turn_on`
  with `variables: {konto: "input_number.zeitkonto_{slug}", minuten: <int>}`
- Validation (balance sufficient, Family Link limit within 0–720 min) happens **in Flutter** before the call
- The script clamps the result to `max(0, current + delta)` as a server-side safety net

---

## HA Side: Required Entities

### 1. Balance helper — one per child

Created automatically by the setup wizard via WebSocket `input_number/create`.
Resulting entity ID: `input_number.zeitkonto_{child_slug}`

```yaml
# Equivalent manual definition (not required — wizard handles this):
input_number:
  zeitkonto_max_mustermann:
    name: "Zeitkonto Max Mustermann"
    min: 0
    max: 600
    step: 5
    unit_of_measurement: min
    icon: mdi:piggy-bank-outline
```

### 2. Balance script (`docs/ha-script-zeitkonto.yaml`)

The script only manages the **balance** entity and is intentionally simple.
Validation (sufficient balance, Family Link limit range) is performed by the Flutter app before calling the script.

```yaml
alias: Zeitkonto aufladen
description: Addiert Minuten zum Zeitkonto eines Kindes
fields:
  konto:
    description: Entity-ID des Zeitkontos (z.B. input_number.zeitkonto_max_mustermann)
    required: true
    selector:
      text:
  minuten:
    description: Minuten hinzufügen (positiv = aufladen, negativ = zurückgeben)
    required: true
    selector:
      number:
        min: -600
        max: 600
sequence:
  - action: input_number.set_value
    target:
      entity_id: "{{ konto }}"
    data:
      value: "{{ [0, (states(konto) | float(0)) + (minuten | float)] | max }}"
mode: queued
max: 5
```

The Family Link daily limit is updated **directly** by the Flutter app via
`POST /api/services/number/set_value` on `number.{child_slug}_{device_id}_today_s_limit`.

---

## Entity Naming Convention (HAFamilyLink)

HAFamilyLink entity IDs follow this pattern:

| Entity type | Pattern |
|---|---|
| Today-limit number | `number.{child_slug}_{device_id}_today_s_limit` |
| Screen-time sensor | `sensor.{child_slug}_device_{device_id}_screen_time` |
| Supervision switch | `switch.familylink_{child_id}_supervision` |

Note: `{child_slug}` is the HA-slugified display name (e.g. `max_mustermann`), **not** the HAFamilyLink `child_id`.
`{device_id}` is the short random suffix visible in the entity ID (e.g. `qzrpiq`).

`EntityDiscovery` uses the **HA entity registry** (WebSocket `config/entity_registry/list`) to find children.
It matches entities whose `unique_id` matches `familylink_{child_id}_{device_id}_today_limit`
and resolves the correct screen-time sensor via `unique_id = familylink_{child_id}_{device_id}_screen_time`.

---

## Security Model

| Credential | Stored? | How |
|---|---|---|
| Admin token | Never | Used only during setup wizard, then discarded |
| Child long-lived token | Yes | Android `EncryptedSharedPreferences` via `FlutterSecureStorage` |

The child HA user has minimal permissions (`system-users` group) and `local_only: true`.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `http` | ^1.2.0 | REST API calls |
| `web_socket_channel` | ^2.4.0 | Setup wizard WS + entity registry |
| `flutter_secure_storage` | ^9.0.0 | Android EncryptedSharedPreferences |
| `shared_preferences` | ^2.2.0 | Non-sensitive prefs (future use) |
| `flutter_launcher_icons` | ^0.14.0 | dev: generate adaptive Android launcher icon |

---

## Implementation Phases

| Phase | Scope |
|---|---|
| **Phase 1** | HA helpers + script; test booking in HA Developer Tools |
| **Phase 2** | ✅ Flutter app MVP: wizard + home screen; registry-based entity discovery; WebSocket balance creation; custom app icon; APK distribution |
| **Phase 3** | Fix restricted-user token creation (proper HA auth flow); custom amount input; connection error UI |
| **Phase 4** | Automated rewards: HA automation topping up balance for reading/learning events |

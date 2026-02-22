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
  └── script.buche_tabletzeit               – booking logic (see below)
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

> **TODO (Phase 2):** The HA WebSocket API only allows a user to create their *own* long-lived token.
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
- Calls `script.buche_tabletzeit` via `POST /api/services/script/turn_on`

---

## HA Side: Required Entities

### 1. Balance helper — one per child

```yaml
input_number:
  zeitkonto_ronja:
    name: "Zeitkonto Ronja"
    min: 0
    max: 600        # configurable per child
    step: 5
    unit_of_measurement: min
    icon: mdi:piggy-bank-outline
```

### 2. Booking script

```yaml
script:
  buche_tabletzeit:
    alias: "Tabletzeit buchen"
    fields:
      kind:
        description: "Child slug (e.g. ronja)"
        example: ronja
      child_id:
        description: "HAFamilyLink child_id"
      device_id:
        description: "HAFamilyLink device_id"
      minuten:
        description: "Minutes to buy (positive) or return (negative)"
        example: 30
    variables:
      balance_entity: "input_number.zeitkonto_{{ kind }}"
      limit_entity: "number.familylink_{{ child_id }}_{{ device_id }}_today_limit"
      sensor_entity: "sensor.familylink_{{ child_id }}_{{ device_id }}_screen_time"
      guthaben: "{{ states(balance_entity) | int }}"
      aktuelles_limit: "{{ states(limit_entity) | int }}"
      verbraucht: "{{ states(sensor_entity) | int }}"
      neues_limit: "{{ aktuelles_limit + minuten }}"
      neues_guthaben: "{{ guthaben - minuten }}"
    sequence:
      - condition: template
        value_template: >-
          {% if minuten > 0 %}
            {{ guthaben >= minuten and neues_limit <= 720 }}
          {% else %}
            {{ neues_limit >= verbraucht and neues_guthaben <= 600 }}
          {% endif %}
      - service: input_number.set_value
        target:
          entity_id: "{{ balance_entity }}"
        data:
          value: "{{ neues_guthaben }}"
      - service: number.set_value
        target:
          entity_id: "{{ limit_entity }}"
        data:
          value: "{{ neues_limit }}"
```

---

## Entity Naming Convention (HAFamilyLink)

HAFamilyLink entity IDs follow this pattern:

| Entity type | Pattern |
|---|---|
| Today-limit number | `number.familylink_{child_id}_{device_id}_today_limit` |
| Screen-time sensor (device) | `sensor.familylink_{child_id}_{device_id}_screen_time` |
| Screen-time sensor (child) | `sensor.familylink_{child_id}_screen_time_today` |
| Supervision switch | `switch.familylink_{child_id}_supervision` |

`EntityDiscovery` reads `child_id` and `device_id` from entity *attributes* (more reliable than parsing the entity ID).

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
| `web_socket_channel` | ^2.4.0 | Setup wizard WS |
| `flutter_secure_storage` | ^9.0.0 | Android EncryptedSharedPreferences |
| `shared_preferences` | ^2.2.0 | Non-sensitive prefs (future use) |

---

## Implementation Phases

| Phase | Scope |
|---|---|
| **Phase 1** | HA helpers + script; test booking in HA Developer Tools |
| **Phase 2** | Flutter app MVP: wizard + home screen (this repo) |
| **Phase 3** | Fix restricted-user token creation (proper HA auth flow); custom amount input; connection error UI |
| **Phase 4** | Automated rewards: HA automation topping up balance for reading/learning events |

# HATabletTime

[![Flutter](https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An Android app that gives each child a **screen-time savings account** managed by Home Assistant.

Children can book tablet time themselves from their device. Parents top up the balance as a reward for reading, learning or helping.
The booked time is automatically applied to the device daily limit via **[HAFamilyLink](https://github.com/JSchmid6/HAFamilyLink)**.

---

## How it works

```
Parent rewards child (reads a book)
  → Parent adds 30 min to child balance in Home Assistant

Child wants to play
  → Opens the app on the tablet
  → Taps "+30 min"
  → App calls HA script → Family Link limit increases by 30 min
  → Balance decreases by 30 min

Child wants to return unused time
  → Taps "− 15 min"
  → Limit decreases, balance increases
```

---

## Requirements

- Home Assistant (2024.1+)
- [HAFamilyLink](https://github.com/JSchmid6/HAFamilyLink) integration installed and configured
- Android tablet (API 26+)

---

## Setup

The app includes a **self-configuring setup wizard**. You only need to do this once per tablet.

1. Install the APK on the tablet
2. Open the app → Setup Wizard starts automatically
3. Enter your Home Assistant URL (e.g. `http://192.168.1.10:8123`)
4. Paste a **long-lived access token** from your HA admin account
   - HA → Profile → Security → Long-lived access tokens → Create
   - This token is used only for setup and discarded afterwards
5. Select which child this tablet belongs to
6. The app automatically:
   - Creates a restricted HA user `tabletapp_{child}`
   - Generates a long-lived token for that user
   - Locates the `input_number.zeitkonto_{child}` entity
   - Identifies the childs FamilyLink device
   - Stores the token securely (Android EncryptedSharedPreferences)
   - Discards the admin token
7. Done - the app starts in the main screen

---

## HA Configuration

### 1. Balance helper (Helpers UI or YAML)

```yaml
input_number:
  zeitkonto_ronja:
    name: "Zeitkonto Ronja"
    min: 0
    max: 600
    step: 5
    unit_of_measurement: min
    icon: mdi:piggy-bank-outline
```

### 2. Booking script

See [`docs/tablet-time-account.md`](https://github.com/JSchmid6/HAFamilyLink/blob/main/docs/tablet-time-account.md) in the HAFamilyLink repo for the full `script.buche_tabletzeit` YAML.

---

## Features

- Balance display with large numbers
- Quick-book buttons: +15 / +30 / +45 / +60 min
- Return time: -15 / -30 min
- Buttons disabled automatically when balance is zero or limits are reached
- Today booked + current limit display
- Kiosk-friendly: full screen, no back-button needed

---

## Development

```bash
git clone https://github.com/JSchmid6/HATabletTime
cd HATabletTime
flutter pub get
flutter run
```

---

## Licence

MIT - see [LICENSE](LICENSE).

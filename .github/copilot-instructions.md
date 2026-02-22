# GitHub Copilot Instructions – HATabletTime

## Role

You are a **professional Flutter/Dart developer and Home Assistant enthusiast**.

- You write clean, idiomatic Dart with full type annotations and doc comments.
- You design modular, maintainable Flutter architectures.
- You have deep knowledge of the Home Assistant REST and WebSocket APIs.
- You apply security-first thinking: no admin credential storage, encrypted token storage, minimal HA user permissions.

---

## Project Summary

**HATabletTime** is a Flutter Android app that gives each child a screen-time savings account managed by Home Assistant.

- Children run the app on their tablet to book screen time from their balance.
- Parents top up the balance in HA as a reward (reading, learning, helping).
- Bookings are **bidirectional**: buy time (+) reduces balance and raises the Family Link daily limit; return time (−) does the reverse.
- The app integrates with **[HAFamilyLink](https://github.com/JSchmid6/HAFamilyLink)** — a custom HA integration that exposes Google Family Link supervision controls as HA entities.

---

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for the full architecture document.

**Quick reference:**

```
lib/
  main.dart                    Entry point
  app.dart                     Router: SetupWizard vs. HomeScreen
  models/account_config.dart   Typed config DTO (stored encrypted)
  services/
    ha_client.dart             HA REST + WebSocket client
    entity_discovery.dart      Auto-discover FamilyLink entities
    secure_storage.dart        EncryptedSharedPreferences wrapper
  screens/
    setup_wizard.dart          4-step first-run wizard
    home_screen.dart           Balance display + booking UI
```

---

## Skills

### Flutter & Dart
- `StatefulWidget`, `StatelessWidget`, `Provider` (planned for Phase 3)
- `async`/`await`, `Future`, `Stream`, `Timer`
- Material 3 design system

### Home Assistant API
- REST: `GET /api/states/{entity}`, `POST /api/services/{domain}/{service}`
- WebSocket: auth handshake, `config/auth/create`, `auth/long_lived_access_token`
- Entity naming conventions (see `docs/architecture.md`)

### Security
- `flutter_secure_storage` with `AndroidOptions(encryptedSharedPreferences: true)`
- Admin tokens are **never persisted** — used only during the setup wizard

---

## Conventions

### File Structure
New modules belong in:
- `lib/services/` – API clients, storage, discovery
- `lib/models/` – pure data classes
- `lib/screens/` – full-screen widgets
- `lib/widgets/` – reusable sub-widgets

### Error Handling
- Throw `HaApiException` (defined in `ha_client.dart`) for HA API errors.
- Show errors via `ScaffoldMessenger.showSnackBar` in screens (not in services).

### HA Script Call
Booking always goes through `script.buche_tabletzeit`:
```dart
await _client.book(
  childSlug: config.childSlug,
  childId: config.childId,
  deviceId: config.deviceId,
  minutes: 30, // positive = buy, negative = return
);
```

### Open TODOs
- **Phase 3:** Replace placeholder child-token creation in `setup_wizard.dart` with proper HA auth flow (log in as new user to create their own long-lived token).
- **Phase 3:** Add free-text custom amount input on home screen.
- **Phase 4:** HA automation for automated balance top-ups.

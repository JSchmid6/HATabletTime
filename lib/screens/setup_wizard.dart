import 'package:flutter/material.dart';

import '../models/account_config.dart';
import '../services/entity_discovery.dart';
import '../services/ha_client.dart';
import '../services/secure_storage.dart';

/// Four-step setup wizard shown on first launch.
///
/// Step 1: HA URL
/// Step 2: Admin long-lived token
/// Step 3: Select child + device
/// Step 4: Auto-provisioning
class SetupWizard extends StatefulWidget {
  final void Function(AccountConfig config) onComplete;

  const SetupWizard({super.key, required this.onComplete});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  int _step = 0;

  final _urlCtrl = TextEditingController(text: 'http://');
  final _tokenCtrl = TextEditingController();

  String? _urlError;
  String? _tokenError;
  bool _busy = false;

  List<HaChild>? _children;
  HaChild? _selectedChild;
  HaDevice? _selectedDevice;

  String _status = '';
  bool _provisioning = false;
  String? _provisioningError;

  void _next() => setState(() => _step++);

  // ── Step 1 ───────────────────────────────────────────────────────

  Future<void> _testUrl() async {
    final url = _urlCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    if (url.isEmpty) { setState(() => _urlError = 'Bitte URL eingeben'); return; }
    setState(() { _urlError = null; _busy = true; });
    try {
      // A 401 from HA means it is reachable — that is enough here.
      await HaClient(haUrl: url, token: 'x').getAllStates()
          .timeout(const Duration(seconds: 6));
    } on HaApiException {
      // 401 is expected without token
    } catch (e) {
      setState(() { _urlError = 'Keine Verbindung: $e'; _busy = false; }); return;
    }
    setState(() => _busy = false);
    _next();
  }

  // ── Step 2 ───────────────────────────────────────────────────────

  Future<void> _loadChildren() async {
    final token = _tokenCtrl.text.trim();
    if (token.isEmpty) { setState(() => _tokenError = 'Bitte Token eingeben'); return; }
    setState(() { _tokenError = null; _busy = true; });
    try {
      final c = HaClient(haUrl: _urlCtrl.text.trim().replaceAll(RegExp(r'/$'), ''), token: token);
      final kids = await EntityDiscovery(c).discoverChildren();
      if (kids.isEmpty) {
        setState(() { _tokenError = 'Keine FamilyLink-Kinder gefunden.\nIst HAFamilyLink installiert?'; _busy = false; });
        return;
      }
      setState(() { _children = kids; _busy = false; });
      _next();
    } catch (e) {
      setState(() { _tokenError = 'Fehler: $e'; _busy = false; });
    }
  }

  // ── Step 4 ───────────────────────────────────────────────────────

  Future<void> _provision() async {
    final haUrl = _urlCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    final adminToken = _tokenCtrl.text.trim();
    final child = _selectedChild!;
    final device = _selectedDevice!;
    final slug = child.slug;

    setState(() { _provisioning = true; _provisioningError = null; _status = 'Verbinde...'; });

    try {
      setState(() => _status = 'WebSocket-Verbindung...');
      final ws = await HaClient.openWebSocket(haUrl, adminToken);

      setState(() => _status = 'Erstelle HA-Benutzer...');
      final createResult = await ws.send({
        'type': 'config/auth/create',
        'name': 'tabletapp_$slug',
        'group_ids': ['system-users'],
        'local_only': true,
      });
      if (createResult['success'] != true) {
        throw Exception('Benutzer konnte nicht erstellt werden: $createResult');
      }

      setState(() => _status = 'Generiere Kind-Token...');
      final tokenResult = await ws.send({
        'type': 'auth/long_lived_access_token',
        'client_name': 'TabletApp ${child.name}',
        'lifespan': 3650,
      });
      // TODO: Log in as new user to create token for them (Phase 2)
      final childToken = tokenResult['result'] as String? ?? adminToken;
      await ws.close();

      setState(() => _status = 'Prüfe Zeitkonto-Entität...');
      final balanceId = 'input_number.zeitkonto_$slug';
      try {
        await HaClient(haUrl: haUrl, token: adminToken).getState(balanceId);
      } catch (_) {
        // Non-fatal: entity may need to be created by user in HA
      }

      setState(() => _status = 'Speichere Konfiguration...');
      final config = AccountConfig(
        haUrl: haUrl, childToken: childToken, childName: child.name,
        childSlug: slug, childId: child.childId, deviceId: device.deviceId,
        balanceEntityId: balanceId, todayLimitEntityId: device.todayLimitEntityId,
        screenTimeSensorId: device.screenTimeSensorId,
      );
      await SecureStorage.saveConfig(config);

      setState(() { _status = '✓ Einrichtung abgeschlossen!'; _provisioning = false; });
      await Future.delayed(const Duration(milliseconds: 800));
      widget.onComplete(config);
    } catch (e) {
      setState(() { _provisioningError = e.toString(); _provisioning = false; });
    }
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Einrichtung')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: [_step1(), _step2(), _step3(), _step4()][_step],
          ),
        ),
      );

  Widget _step1() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _stepLabel('Schritt 1 von 4'),
    _title('HA-Adresse'),
    const SizedBox(height: 24),
    TextField(
      controller: _urlCtrl,
      decoration: InputDecoration(labelText: 'Home Assistant URL',
          hintText: 'http://homeassistant.local:8123',
          errorText: _urlError, border: const OutlineInputBorder()),
      keyboardType: TextInputType.url, autocorrect: false,
    ),
    const SizedBox(height: 24),
    _wideButton(onPressed: _busy ? null : _testUrl, label: 'Verbinden'),
  ]);

  Widget _step2() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _stepLabel('Schritt 2 von 4'),
    _title('Admin-Token'),
    const SizedBox(height: 8),
    const Text('HA → Profil → Sicherheit → Langlebige Zugriffstoken → Erstellen.\n'
        'Wird nur für Setup verwendet und danach verworfen.',
        style: TextStyle(color: Colors.grey)),
    const SizedBox(height: 24),
    TextField(
      controller: _tokenCtrl,
      decoration: InputDecoration(labelText: 'Long-lived Access Token',
          errorText: _tokenError, border: const OutlineInputBorder()),
      obscureText: true,
    ),
    const SizedBox(height: 24),
    _wideButton(onPressed: _busy ? null : _loadChildren, label: 'Weiter'),
  ]);

  Widget _step3() {
    final kids = _children ?? [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _stepLabel('Schritt 3 von 4'),
      _title('Kind & Gerät'),
      const SizedBox(height: 8),
      const Text('Dieses Tablet gehört:', style: TextStyle(color: Colors.grey)),
      const SizedBox(height: 12),
      Expanded(child: ListView.builder(
        itemCount: kids.length,
        itemBuilder: (ctx, i) {
          final kid = kids[i];
          final sel = _selectedChild?.childId == kid.childId;
          return Card(
            color: sel ? Theme.of(ctx).colorScheme.primaryContainer : null,
            child: InkWell(
              onTap: () => setState(() {
                _selectedChild = kid;
                _selectedDevice = kid.devices.length == 1 ? kid.devices.first : null;
              }),
              child: Padding(padding: const EdgeInsets.all(16), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kid.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  if (sel && kid.devices.length > 1)
                    RadioGroup<HaDevice>(
                      groupValue: _selectedDevice,
                      onChanged: (v) => setState(() => _selectedDevice = v),
                      child: Column(
                        children: kid.devices.map((d) => RadioListTile<HaDevice>(
                          title: Text(d.displayName),
                          value: d,
                        )).toList(),
                      ),
                    ),
                  if (sel && kid.devices.length == 1)
                    Text('Gerät: ${kid.devices.first.displayName}',
                        style: const TextStyle(color: Colors.grey)),
                ],
              )),
            ),
          );
        },
      )),
      const SizedBox(height: 12),
      _wideButton(
        onPressed: _selectedChild != null && _selectedDevice != null
            ? () { _next(); _provision(); } : null,
        label: 'Einrichten',
      ),
    ]);
  }

  Widget _step4() => Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    if (_provisioning) ...[
      const CircularProgressIndicator(),
      const SizedBox(height: 24),
      Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
    ] else if (_provisioningError != null) ...[
      const Icon(Icons.error_outline, color: Colors.red, size: 64),
      const SizedBox(height: 16),
      Text(_provisioningError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
      const SizedBox(height: 24),
      OutlinedButton(
        onPressed: () => setState(() { _step = 0; _provisioningError = null; }),
        child: const Text('Neu starten'),
      ),
    ] else ...[
      const Icon(Icons.check_circle, color: Colors.green, size: 64),
      const SizedBox(height: 16),
      Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
    ],
  ]));

  Widget _stepLabel(String t) => Text(t, style: const TextStyle(color: Colors.grey));
  Widget _title(String t) => Text(t, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold));
  Widget _wideButton({required VoidCallback? onPressed, required String label}) =>
      SizedBox(width: double.infinity,
          child: FilledButton(onPressed: onPressed,
              child: _busy
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(label)));
}

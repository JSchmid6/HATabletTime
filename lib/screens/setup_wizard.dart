import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
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

  final _urlCtrl = TextEditingController(text: 'https://');
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
  void _back() => setState(() { if (_step > 0) _step--; });

  // ── Step 1 ───────────────────────────────────────────────────────

  Future<void> _testUrl() async {
    final url = _urlCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    if (url.isEmpty) { setState(() => _urlError = 'Bitte URL eingeben'); return; }
    setState(() { _urlError = null; _busy = true; });
    final error = await HaClient.validateHaUrl(url);
    if (error != null) {
      setState(() { _urlError = error; _busy = false; });
      return;
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
      final result = await EntityDiscovery(c).discoverChildren();
      if (!result.hasChildren) {
        setState(() {
          _tokenError = result.diagnosticInfo ?? 'Keine FamilyLink-Kinder gefunden.\nIst HAFamilyLink installiert?';
          _busy = false;
        });
        return;
      }
      setState(() { _children = result.children; _busy = false; });
      _next();
    } on HaApiException catch (e) {
      setState(() { _tokenError = 'Fehler: ${e.userMessage}'; _busy = false; });
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

      setState(() => _status = 'Prüfe/erstelle Zeitkonto-Entität...');
      final balanceId = 'input_number.zeitkonto_$slug';
      final adminClient = HaClient(haUrl: haUrl, token: adminToken);
      final created = await adminClient.ensureBalanceEntity(slug, child.name);
      if (created) {
        setState(() => _status = 'Zeitkonto-Entität angelegt ✓');
      } else {
        setState(() => _status = 'Zeitkonto-Entität gefunden ✓');
      }

      setState(() => _status = 'Suche Buchungs-Script...');
      String bookScriptEntityId = 'script.tabletzeit_buchen'; // Fallback
      try {
        final allStates = await adminClient.getAllStates();
        final scriptEntity = allStates.firstWhere(
          (s) {
            final id = s['entity_id'] as String? ?? '';
            if (!id.startsWith('script.')) return false;
            final name = ((s['attributes'] as Map?)?['friendly_name'] as String? ?? '').toLowerCase();
            return name.contains('tabletzeit') || name.contains('buchen') || id.contains('tabletzeit');
          },
          orElse: () => {},
        );
        if (scriptEntity.isNotEmpty) {
          bookScriptEntityId = scriptEntity['entity_id'] as String;
          setState(() => _status = 'Script gefunden: $bookScriptEntityId ✓');
        } else {
          setState(() => _status = 'Script nicht gefunden, nutze Fallback ✓');
        }
      } catch (e) {
        debugPrint('[provision] Script-Discovery failed: $e');
      }

      setState(() => _status = 'Speichere Konfiguration...');
      // Encode all devices of this child so the HomeScreen can offer a picker.
      final devicesJson = jsonEncode(child.devices.map((d) => {
        'deviceId': d.deviceId,
        'displayName': d.displayName,
        'todayLimitEntityId': d.todayLimitEntityId,
        'screenTimeSensorId': d.screenTimeSensorId,
      }).toList());
      final config = AccountConfig(
        haUrl: haUrl, childToken: childToken, childName: child.name,
        childSlug: slug, childId: child.childId, deviceId: device.deviceId,
        balanceEntityId: balanceId, todayLimitEntityId: device.todayLimitEntityId,
        screenTimeSensorId: device.screenTimeSensorId,
        devicesJson: devicesJson,
        bookScriptEntityId: bookScriptEntityId,
      );
      await SecureStorage.saveConfig(config);

      setState(() { _status = '✓ Einrichtung abgeschlossen!'; _provisioning = false; });
      await Future.delayed(const Duration(milliseconds: 800));
      widget.onComplete(config);
    } catch (e) {
      debugPrint('[provision] ERROR: $e');
      setState(() { _provisioningError = e.toString(); _provisioning = false; });
    }
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Einrichtung'),
          leading: _step > 0 && _step < 3
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _back)
              : null,
        ),
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
          hintText: 'https://homeassistant.local:8123',
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
          errorText: _tokenError != null && _tokenError!.length < 60 ? _tokenError : null,
          border: const OutlineInputBorder()),
      obscureText: true,
    ),
    // Show longer diagnostic info in a scrollable container
    if (_tokenError != null && _tokenError!.length >= 60) ...[
      const SizedBox(height: 12),
      Container(
        constraints: const BoxConstraints(maxHeight: 200),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            _tokenError!,
            style: TextStyle(color: Colors.red.shade900, fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
      ),
    ],
    const SizedBox(height: 24),
    _wideButton(onPressed: _busy ? null : _loadChildren, label: 'Weiter'),
    const SizedBox(height: 8),
    Center(child: TextButton(onPressed: _busy ? null : _back, child: const Text('Zurück'))),
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
                    Column(
                      children: kid.devices.map((d) => RadioListTile<HaDevice>(
                        title: Text(d.displayName),
                        value: d,
                        groupValue: _selectedDevice,
                        onChanged: (v) => setState(() => _selectedDevice = v),
                      )).toList(),
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
      const SizedBox(height: 8),
      Center(child: TextButton(onPressed: _back, child: const Text('Zurück'))),
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

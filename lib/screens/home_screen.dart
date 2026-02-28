import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import '../models/account_config.dart';
import '../services/ha_client.dart';

/// Main screen: shows balance and booking/return buttons.
class HomeScreen extends StatefulWidget {
  final AccountConfig config;
  const HomeScreen({super.key, required this.config});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HaClient _client;
  late List<StoredDevice> _allDevices;
  late StoredDevice _activeDevice;

  int _balance = 0;
  int _todayLimit = 0;
  int _usedToday = 0;

  bool _loading = true;
  String? _error;
  bool _booking = false;
  bool _confirming = false; // verhindert doppelte Dialoge bei schnellem Tippen
  bool _refreshing = false; // verhindert Aufstauen von parallelen Poll-Requests

  Timer? _timer;
  int _fastPollRemaining = 0;

  @override
  void initState() {
    super.initState();
    _client = HaClient(haUrl: widget.config.haUrl, token: widget.config.childToken);
    _allDevices = widget.config.allDevices;
    // Default to the device that was selected during setup
    _activeDevice = _allDevices.firstWhere(
      (d) => d.deviceId == widget.config.deviceId,
      orElse: () => _allDevices.first,
    );
    _refresh();
    _startNormalPolling();
  }

  void _startNormalPolling() {
    _timer?.cancel();
    _fastPollRemaining = 0;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  /// Nach einer Buchung: 5× alle 2 Sekunden pollen (~10 Sek.), dann zurück auf 30 Sek.
  void _startFastPolling() {
    _timer?.cancel();
    _fastPollRemaining = 5;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refresh();
      _fastPollRemaining--;
      if (_fastPollRemaining <= 0) _startNormalPolling();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return; // vorheriger Request noch unterwegs → überspringen
    _refreshing = true;
    try {
    final balanceId  = widget.config.balanceEntityId;
    final limitId    = _activeDevice.todayLimitEntityId;
    final sensorId   = _activeDevice.screenTimeSensorId;
    debugPrint('[HomeScreen] refresh – balance=$balanceId  limit=$limitId  sensor=$sensorId');

    Map<String, dynamic> b = {}, l = {}, s = {};
    final errors = <String>[];

    await Future.wait([
      _client.getState(balanceId).then((r) => b = r).catchError((e) {
        debugPrint('[HomeScreen] balance ERROR: $e');
        errors.add('Guthaben ($balanceId): $e');
        return <String, dynamic>{};
      }),
      _client.getState(limitId).then((r) => l = r).catchError((e) {
        debugPrint('[HomeScreen] limit ERROR: $e');
        errors.add('Limit ($limitId): $e');
        return <String, dynamic>{};
      }),
      _client.getState(sensorId).then((r) => s = r).catchError((e) {
        debugPrint('[HomeScreen] sensor ERROR: $e');
        errors.add('Sensor ($sensorId): $e');
        return <String, dynamic>{};
      }),
    ]);

    debugPrint('[HomeScreen] states – balance=${b['state']} limit=${l['state']} used=${s['state']}');

    setState(() {
      _balance    = (double.tryParse(b['state'] as String? ?? '') ?? 0).round();
      _todayLimit = (double.tryParse(l['state'] as String? ?? '') ?? 0).round();
      _usedToday  = (double.tryParse(s['state'] as String? ?? '') ?? 0).round();
      _loading = false;
      _error = errors.isNotEmpty ? errors.join('\n') : null;
    });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _book(int minutes) async {
    debugPrint('[HomeScreen] _book($minutes) called');
    if (_booking) return;
    setState(() => _booking = true);
    try {
      debugPrint('[HomeScreen] calling book() – slug=${widget.config.childSlug}'
          ' limitEntity=${_activeDevice.todayLimitEntityId}');
      await _client.book(
        childSlug: widget.config.childSlug,
        childId: widget.config.childId,
        deviceId: _activeDevice.deviceId,
        limitEntityId: _activeDevice.todayLimitEntityId,
        screenTimeSensorId: _activeDevice.screenTimeSensorId,
        scriptEntityId: widget.config.bookScriptEntityId,
        minutes: minutes,
      );
      // Optimistischer Update: lokalen State sofort anpassen damit _enabled()
      // bei der nächsten Buchung schon mit den korrekten Erwartungswerten rechnet –
      // auch bevor HA das Ergebnis zurückgemeldet hat.
      setState(() {
        _balance    -= minutes;   // Guthaben sinkt beim Kaufen, steigt beim Zurückgeben
        _todayLimit += minutes;   // Limit steigt beim Kaufen, sinkt beim Zurückgeben
      });
      await _refresh();
      _startFastPolling(); // alle 2 Sek. pollen bis HA den echten Wert bestätigt
    } catch (e) {
      // Sofort resync – optimistische Werte könnten falsch sein
      _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _booking = false);
    }
  }

  Future<void> _confirm(int minutes) async {
    if (_confirming || _booking) return;
    setState(() => _confirming = true);
    debugPrint('[HomeScreen] _confirm($minutes) – showing dialog');
    final label = minutes > 0 ? '+$minutes min buchen' : '${minutes.abs()} min zurückgeben';
    final ok = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Text(minutes > 0
            ? 'Guthaben danach: ${_balance - minutes} min'
            : 'Guthaben danach: ${_balance + minutes.abs()} min'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    // _confirming bleibt true bis _book() vollständig abgeschlossen —
    // so sind Buttons während der gesamten Transaktion gesperrt.
    if (ok == true) await _book(minutes);
    setState(() => _confirming = false);
    debugPrint('[HomeScreen] _confirm result: ok=$ok');
  }

  bool _enabled(int minutes) {
    if (minutes > 0) return _balance >= minutes && (_todayLimit + minutes) <= 720;
    return (_todayLimit + minutes) >= _usedToday;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _body(),
    ),
  );

  Widget _body() {
    return OrientationBuilder(
      builder: (context, orientation) => orientation == Orientation.landscape
          ? _bodyLandscape()
          : _bodyPortrait(),
    );
  }

  // ── Portrait ───────────────────────────────────────────────────────────────

  Widget _bodyPortrait() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(children: [
        Text('${widget.config.childName}s Zeitkonto',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_allDevices.length > 1) ..._buildDevicePicker(),
        _balanceCard(cs),
        const SizedBox(height: 12),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        _sectionLabel('Zeit buchen'),
        const SizedBox(height: 6),
        _grid([15, 30, 45, 60], isReturn: false),
        const SizedBox(height: 10),
        _sectionLabel('Zeit zurückgeben'),
        const SizedBox(height: 6),
        _grid([15, 30], isReturn: true),
        const SizedBox(height: 12),
        const Divider(),
        _row('Aktuelles Limit', '$_todayLimit min'),
        _row('Heute verbraucht', '$_usedToday min'),
        const Spacer(),
        TextButton.icon(
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Aktualisieren'),
        ),
      ]),
    );
  }

  // ── Landscape ─────────────────────────────────────────────────────────────

  Widget _bodyLandscape() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Left: balance + stats
        Expanded(
          flex: 2,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${widget.config.childName}s Zeitkonto',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_allDevices.length > 1) ..._buildDevicePicker(),
            _balanceCard(cs, compact: true),
            const SizedBox(height: 8),
            const Divider(),
            _row('Aktuelles Limit', '$_todayLimit min'),
            _row('Heute verbraucht', '$_usedToday min'),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Aktualisieren', style: TextStyle(fontSize: 13)),
            ),
          ]),
        ),
        const SizedBox(width: 20),
        // Right: booking buttons
        Expanded(
          flex: 3,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            _sectionLabel('Zeit buchen'),
            const SizedBox(height: 4),
            _grid([15, 30, 45, 60], isReturn: false),
            const SizedBox(height: 8),
            _sectionLabel('Zeit zurückgeben'),
            const SizedBox(height: 4),
            _grid([15, 30], isReturn: true, columns: 4),
          ]),
        ),
      ]),
    );
  }

  Widget _balanceCard(ColorScheme cs, {bool compact = false}) => Container(
    width: double.infinity,
    padding: EdgeInsets.symmetric(vertical: compact ? 10 : 20),
    decoration: BoxDecoration(
        color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
    child: Column(children: [
      if (!compact) const Text('⏱', style: TextStyle(fontSize: 36)),
      Text('$_balance',
          style: (compact
                  ? Theme.of(context).textTheme.displayMedium
                  : Theme.of(context).textTheme.displayLarge)
              ?.copyWith(color: cs.onPrimaryContainer)),
      Text('Minuten Guthaben',
          style: TextStyle(color: cs.onPrimaryContainer, fontSize: compact ? 13 : 15)),
    ]),
  );

  Widget _sectionLabel(String t) => Align(
      alignment: Alignment.centerLeft,
      child: Text(t, style: const TextStyle(color: Colors.grey)));

  List<Widget> _buildDevicePicker() => [
    SegmentedButton<String>(
      segments: _allDevices
          .map((d) => ButtonSegment<String>(
                value: d.deviceId,
                label: Text(d.displayName, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      selected: {_activeDevice.deviceId},
      onSelectionChanged: (sel) {
        final picked = _allDevices.firstWhere((d) => d.deviceId == sel.first);
        setState(() {
          _activeDevice = picked;
          _loading = true;
        });
        _refresh();
      },
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
      ),
    ),
    const SizedBox(height: 8),
  ];

  Widget _grid(List<int> amounts, {required bool isReturn, int? columns}) =>
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: columns ?? amounts.length,
        childAspectRatio: 2.2,
        mainAxisSpacing: 8, crossAxisSpacing: 8,
        children: amounts.map((amt) {
          final min = isReturn ? -amt : amt;
          return FilledButton(
            onPressed: (_booking || _confirming || !_enabled(min)) ? null : () => _confirm(min),
            style: isReturn
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.secondary)
                : null,
            child: Text(isReturn ? '−$amt min' : '+$amt min',
                style: const TextStyle(fontSize: 15)),
          );
        }).toList(),
      );

  Widget _row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]));
}

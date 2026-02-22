import 'dart:async';

import 'package:flutter/material.dart';

import '../models/account_config.dart';
import '../services/ha_client.dart';
import '../services/secure_storage.dart';

/// Main screen: shows balance and booking/return buttons.
class HomeScreen extends StatefulWidget {
  final AccountConfig config;
  const HomeScreen({super.key, required this.config});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HaClient _client;

  int _balance = 0;
  int _todayLimit = 0;
  int _usedToday = 0;
  int _bookedToday = 0;

  bool _loading = true;
  String? _error;
  bool _booking = false;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _client = HaClient(haUrl: widget.config.haUrl, token: widget.config.childToken);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final b = await _client.getState(widget.config.balanceEntityId);
      final l = await _client.getState(widget.config.todayLimitEntityId);
      final s = await _client.getState(widget.config.screenTimeSensorId);
      setState(() {
        _balance = (double.tryParse(b['state'] as String) ?? 0).round();
        _todayLimit = (double.tryParse(l['state'] as String) ?? 0).round();
        _usedToday = (double.tryParse(s['state'] as String) ?? 0).round();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() { _error = 'Verbindungsfehler'; _loading = false; });
    }
  }

  Future<void> _book(int minutes) async {
    if (_booking) return;
    setState(() => _booking = true);
    try {
      await _client.book(
        childSlug: widget.config.childSlug,
        childId: widget.config.childId,
        deviceId: widget.config.deviceId,
        minutes: minutes,
      );
      setState(() => _bookedToday += minutes);
      await _refresh();
    } catch (e) {
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
    if (ok == true) _book(minutes);
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
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(children: [
        Text('${widget.config.childName}s Zeitkonto',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),

        // Balance card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
              color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            const Text('⏱', style: TextStyle(fontSize: 36)),
            Text('$_balance', style: Theme.of(context).textTheme.displayLarge
                ?.copyWith(color: cs.onPrimaryContainer)),
            Text('Minuten Guthaben',
                style: TextStyle(color: cs.onPrimaryContainer, fontSize: 15)),
          ]),
        ),
        const SizedBox(height: 12),

        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),

        // Buy buttons
        _sectionLabel('Zeit buchen'),
        const SizedBox(height: 6),
        _grid([15, 30, 45, 60], isReturn: false),
        const SizedBox(height: 10),

        // Return buttons
        _sectionLabel('Zeit zurückgeben'),
        const SizedBox(height: 6),
        _grid([15, 30], isReturn: true),
        const SizedBox(height: 12),

        const Divider(),
        _row('Heute gebucht', '$_bookedToday min'),
        _row('Aktuelles Limit', '$_todayLimit min'),
        _row('Heute verbraucht', '$_usedToday min'),

        const Spacer(),
        TextButton.icon(
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Aktualisieren'),
        ),
        TextButton(
          onPressed: () async {
            final ok = await showDialog<bool>(context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Zurücksetzen?'),
                content: const Text('App-Konfiguration löschen und Setup neu starten?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                  TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Zurücksetzen')),
                ],
              ),
            );
            if (ok == true) {
              await SecureStorage.clearConfig();
              if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
            }
          },
          child: const Text('Setup wiederholen', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _sectionLabel(String t) => Align(
      alignment: Alignment.centerLeft,
      child: Text(t, style: const TextStyle(color: Colors.grey)));

  Widget _grid(List<int> amounts, {required bool isReturn}) =>
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: amounts.length,
        childAspectRatio: 2.2,
        mainAxisSpacing: 8, crossAxisSpacing: 8,
        children: amounts.map((amt) {
          final min = isReturn ? -amt : amt;
          return FilledButton(
            onPressed: (_booking || !_enabled(min)) ? null : () => _confirm(min),
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

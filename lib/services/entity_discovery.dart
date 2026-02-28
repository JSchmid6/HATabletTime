import 'package:flutter/foundation.dart';
import 'ha_client.dart';

class DiscoveryResult {
  final List<HaChild> children;
  final String? diagnosticInfo;
  const DiscoveryResult({required this.children, this.diagnosticInfo});
  bool get hasChildren => children.isNotEmpty;
}

class EntityDiscovery {
  final HaClient client;
  EntityDiscovery(this.client);

  Future<DiscoveryResult> discoverChildren() async {
    final states = await client.getAllStates();
    debugPrint('-- EntityDiscovery: ${states.length} entities total --');

    final todayLimitStates = states.where((s) {
      final id = s['entity_id'] as String;
      if (!id.startsWith('number.') || !id.endsWith('_today_s_limit')) return false;
      final attrs = s['attributes'] as Map<String, dynamic>? ?? {};
      return attrs.containsKey('child_id');
    }).toList();

    debugPrint('-- TodayLimit candidates: ${todayLimitStates.length} --');
    for (final e in todayLimitStates) {
      final attrs = e['attributes'] as Map<String, dynamic>? ?? {};
      debugPrint('  ${e['entity_id']} child_id=${attrs['child_id']}');
    }

    if (todayLimitStates.isEmpty) {
      return _noChildren(states, 'Keine number.*_today_s_limit Entities gefunden.\nIst HAFamilyLink installiert?');
    }

    final entityIdToUniqueId = <String, String>{};
    try {
      final registryEntries = await HaClient.getEntityRegistryViaWs(client.haUrl, client.token);
      for (final entry in registryEntries) {
        final entityId = entry['entity_id'] as String? ?? '';
        final uniqueId = entry['unique_id'] as String? ?? '';
        if (uniqueId.isNotEmpty) entityIdToUniqueId[entityId] = uniqueId;
      }
      debugPrint('-- Registry entries: ${registryEntries.length} --');
    } catch (e) {
      debugPrint('-- Registry fetch failed: $e (falling back to sensor attr) --');
    }

    final childNameMap = <String, String>{};
    for (final s in states) {
      final id = s['entity_id'] as String;
      if (!id.startsWith('sensor.') || !id.endsWith('_screen_time_today')) continue;
      final attrs = s['attributes'] as Map<String, dynamic>? ?? {};
      final childId = attrs['child_id'] as String?;
      if (childId == null || childId.isEmpty) continue;
      final friendly = (attrs['friendly_name'] as String? ?? '')
          .replaceAll(RegExp(r'\s*screen time today\s*', caseSensitive: false), '').trim();
      if (friendly.isNotEmpty) childNameMap[childId] = friendly;
    }

    final childMap = <String, _ChildBuilder>{};
    for (final entity in todayLimitStates) {
      final entityId = entity['entity_id'] as String;
      final attrs = entity['attributes'] as Map<String, dynamic>? ?? {};
      final childId = attrs['child_id'] as String? ?? '';
      if (childId.isEmpty) continue;

      final base = entityId.substring('number.'.length, entityId.length - '_today_s_limit'.length);

      String? deviceId;
      final uniqueId = entityIdToUniqueId[entityId];
      if (uniqueId != null) {
        final prefix = 'familylink_${childId}_';
        const suffix = '_today_limit';
        if (uniqueId.startsWith(prefix) && uniqueId.endsWith(suffix)) {
          deviceId = uniqueId.substring(prefix.length, uniqueId.length - suffix.length);
          debugPrint('  $entityId -> device_id=$deviceId (registry)');
        } else {
          debugPrint('  $entityId unique_id=$uniqueId did not match pattern');
        }
      }

      if (deviceId == null || deviceId.isEmpty) {
        for (final s in states) {
          final sId = s['entity_id'] as String;
          if (sId != 'sensor.${base}_screen_time') continue;
          final sAttrs = s['attributes'] as Map<String, dynamic>? ?? {};
          deviceId = sAttrs['device_id'] as String?;
          debugPrint('  $entityId -> device_id=$deviceId (sensor fallback)');
          break;
        }
      }

      if (deviceId == null || deviceId.isEmpty) {
        debugPrint('  SKIP $entityId -- could not determine device_id');
        continue;
      }

      // Find the screen_time sensor's entity_id via registry (unique_id pattern).
      // Its unique_id is "familylink_{childId}_{deviceId}_screen_time".
      final screenTimeUniqueId = 'familylink_${childId}_${deviceId}_screen_time';
      String sensorId = entityIdToUniqueId.entries
          .where((e) => e.value == screenTimeUniqueId)
          .map((e) => e.key)
          .firstOrNull
          ?? 'sensor.${base}_screen_time'; // fallback (may be wrong for devices with '_device_' in slug)
      debugPrint('  screenTimeSensorId=$sensorId');
      final displayName = attrs['friendly_name'] as String? ?? base;

      childMap.putIfAbsent(childId, () {
        final name = childNameMap[childId] ?? childId;
        return _ChildBuilder(childId: childId, name: name);
      });
      childMap[childId]!.devices.add(HaDevice(
        deviceId: deviceId,
        displayName: displayName,
        todayLimitEntityId: entityId,
        screenTimeSensorId: sensorId,
      ));
    }

    final children = childMap.values
        .where((b) => b.devices.isNotEmpty)
        .map((b) => b.build())
        .toList();

    debugPrint('-- Found ${children.length} children --');
    if (children.isNotEmpty) return DiscoveryResult(children: children);
    return _noChildren(states, null);
  }

  DiscoveryResult _noChildren(List<Map<String, dynamic>> states, String? overrideMsg) {
    final buf = StringBuffer();
    buf.writeln('Keine HAFamilyLink-Kinder gefunden.\n');
    if (overrideMsg != null) {
      buf.writeln(overrideMsg);
      return DiscoveryResult(children: [], diagnosticInfo: buf.toString());
    }
    final todayCandidates = states
        .where((s) => (s['entity_id'] as String).endsWith('_today_s_limit'))
        .toList();
    if (todayCandidates.isEmpty) {
      buf.writeln('Keine number.*_today_s_limit Entities gefunden.\nIst HAFamilyLink installiert?');
    } else {
      buf.writeln('${todayCandidates.length} *_today_s_limit Entities gefunden, aber keine device_id ermittelbar:\n');
      for (final e in todayCandidates) {
        final attrs = e['attributes'] as Map<String, dynamic>? ?? {};
        buf.writeln('  ${e['entity_id']}');
        buf.writeln('    Attribute: ${attrs.keys.join(', ')}');
      }
    }
    final info = buf.toString();
    debugPrint(info);
    return DiscoveryResult(children: [], diagnosticInfo: info);
  }
}

class _ChildBuilder {
  final String childId;
  String name;
  final List<HaDevice> devices;

  _ChildBuilder({required this.childId, String? name})
      : name = name ?? childId,
        devices = [];

  HaChild build() => HaChild(
        name: name,
        childId: childId,
        slug: name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_'),
        devices: devices,
      );
}
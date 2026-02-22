import 'ha_client.dart';

/// Discovers FamilyLink children and devices from Home Assistant entity states.
class EntityDiscovery {
  final HaClient client;

  EntityDiscovery(this.client);

  Future<List<HaChild>> discoverChildren() async {
    final states = await client.getAllStates();

    final todayLimitEntities = states
        .where((s) =>
            (s['entity_id'] as String).startsWith('number.') &&
            (s['entity_id'] as String).endsWith('_today_limit') &&
            (s['entity_id'] as String).contains('familylink'))
        .toList();

    final childMap = <String, _ChildBuilder>{};

    for (final entity in todayLimitEntities) {
      final attrs = entity['attributes'] as Map<String, dynamic>? ?? {};
      final entityId = entity['entity_id'] as String;

      final childId = attrs['child_id'] as String? ?? '';
      final deviceId = attrs['device_id'] as String? ?? '';
      if (childId.isEmpty || deviceId.isEmpty) continue;

      final sensorId = entityId
          .replaceFirst('number.', 'sensor.')
          .replaceFirst('_today_limit', '_screen_time');

      childMap.putIfAbsent(childId, () => _ChildBuilder(childId: childId));
      childMap[childId]!.devices.add(HaDevice(
        deviceId: deviceId,
        displayName: attrs['friendly_name'] as String? ?? deviceId,
        todayLimitEntityId: entityId,
        screenTimeSensorId: sensorId,
      ));
    }

    // Enrich with child names from supervision switch attributes
    for (final sw in states.where((s) =>
        (s['entity_id'] as String).startsWith('switch.') &&
        (s['entity_id'] as String).contains('familylink') &&
        (s['entity_id'] as String).endsWith('_supervision'))) {
      final attrs = sw['attributes'] as Map<String, dynamic>? ?? {};
      final childId = attrs['child_id'] as String? ?? '';
      if (childId.isNotEmpty && childMap.containsKey(childId)) {
        final rawName = (attrs['friendly_name'] as String? ?? '')
            .replaceFirst(' Supervision', '')
            .trim();
        if (rawName.isNotEmpty) childMap[childId]!.name = rawName;
      }
    }

    return childMap.values
        .where((b) => b.devices.isNotEmpty)
        .map((b) => b.build())
        .toList();
  }
}

class _ChildBuilder {
  final String childId;
  String name;
  final List<HaDevice> devices;

  _ChildBuilder({required this.childId})
      : name = childId,
        devices = [];

  HaChild build() => HaChild(
        name: name,
        childId: childId,
        slug: name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_'),
        devices: devices,
      );
}

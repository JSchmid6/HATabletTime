import 'dart:convert';

/// A single bookable device stored in the account config.
class StoredDevice {
  final String deviceId;
  final String displayName;
  final String todayLimitEntityId;
  final String screenTimeSensorId;

  const StoredDevice({
    required this.deviceId,
    required this.displayName,
    required this.todayLimitEntityId,
    required this.screenTimeSensorId,
  });

  Map<String, String> toMap() => {
    'deviceId': deviceId,
    'displayName': displayName,
    'todayLimitEntityId': todayLimitEntityId,
    'screenTimeSensorId': screenTimeSensorId,
  };

  factory StoredDevice.fromMap(Map<String, dynamic> m) => StoredDevice(
    deviceId: m['deviceId'] as String,
    displayName: m['displayName'] as String,
    todayLimitEntityId: m['todayLimitEntityId'] as String,
    screenTimeSensorId: m['screenTimeSensorId'] as String,
  );
}

class AccountConfig {
  final String haUrl;
  final String childToken;
  final String childName;
  final String childSlug;
  final String childId;
  final String deviceId;
  final String balanceEntityId;
  final String todayLimitEntityId;
  final String screenTimeSensorId;
  /// JSON-encoded list of all devices for this child.
  /// Empty string = only the single device from [deviceId] fields.
  final String devicesJson;
  /// Entity-ID des Buchungs-Scripts (z.B. script.tabletzeit_buchen).
  final String bookScriptEntityId;

  const AccountConfig({
    required this.haUrl,
    required this.childToken,
    required this.childName,
    required this.childSlug,
    required this.childId,
    required this.deviceId,
    required this.balanceEntityId,
    required this.todayLimitEntityId,
    required this.screenTimeSensorId,
    this.devicesJson = '',
    this.bookScriptEntityId = 'script.tabletzeit_buchen',
  });

  /// All bookable devices for this child.
  /// Falls back to a single device built from the primary fields.
  List<StoredDevice> get allDevices {
    if (devicesJson.isNotEmpty) {
      try {
        final list = json.decode(devicesJson) as List<dynamic>;
        if (list.isNotEmpty) {
          return list
              .cast<Map<String, dynamic>>()
              .map(StoredDevice.fromMap)
              .toList();
        }
      } catch (_) {}
    }
    return [
      StoredDevice(
        deviceId: deviceId,
        displayName: deviceId,
        todayLimitEntityId: todayLimitEntityId,
        screenTimeSensorId: screenTimeSensorId,
      )
    ];
  }

  Map<String, String> toMap() => {
    'haUrl': haUrl, 'childToken': childToken, 'childName': childName,
    'childSlug': childSlug, 'childId': childId, 'deviceId': deviceId,
    'balanceEntityId': balanceEntityId, 'todayLimitEntityId': todayLimitEntityId,
    'screenTimeSensorId': screenTimeSensorId,
    'devicesJson': devicesJson,
    'bookScriptEntityId': bookScriptEntityId,
  };

  AccountConfig copyWith({String? haUrl, String? bookScriptEntityId}) => AccountConfig(
    haUrl: haUrl ?? this.haUrl,
    childToken: childToken, childName: childName, childSlug: childSlug,
    childId: childId, deviceId: deviceId, balanceEntityId: balanceEntityId,
    todayLimitEntityId: todayLimitEntityId, screenTimeSensorId: screenTimeSensorId,
    devicesJson: devicesJson,
    bookScriptEntityId: bookScriptEntityId ?? this.bookScriptEntityId,
  );

  factory AccountConfig.fromMap(Map<String, String> m) => AccountConfig(
    haUrl: m['haUrl']!, childToken: m['childToken']!, childName: m['childName']!,
    childSlug: m['childSlug']!, childId: m['childId']!, deviceId: m['deviceId']!,
    balanceEntityId: m['balanceEntityId']!, todayLimitEntityId: m['todayLimitEntityId']!,
    screenTimeSensorId: m['screenTimeSensorId']!,
    devicesJson: m['devicesJson'] ?? '',
    bookScriptEntityId: m['bookScriptEntityId'] ?? 'script.tabletzeit_buchen',
  );
}

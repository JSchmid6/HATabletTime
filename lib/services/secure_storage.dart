import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "../models/account_config.dart";

class SecureStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _prefix = "ha_tablet_time_";

  static Future<void> saveConfig(AccountConfig config) async {
    for (final e in config.toMap().entries) {
      await _storage.write(key: "$_prefix${e.key}", value: e.value);
    }
  }

  static Future<AccountConfig?> loadConfig() async {
    final keys = const AccountConfig(
      haUrl: "", childToken: "", childName: "", childSlug: "",
      childId: "", deviceId: "", balanceEntityId: "",
      todayLimitEntityId: "", screenTimeSensorId: "",
    ).toMap().keys.toList();
    final map = <String, String>{};
    for (final key in keys) {
      final value = await _storage.read(key: "$_prefix$key");
      if (value == null) return null;
      map[key] = value;
    }
    return AccountConfig.fromMap(map);
  }

  static Future<void> clearConfig() => _storage.deleteAll();
}

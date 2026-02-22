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
  });

  Map<String, String> toMap() => {
    "haUrl": haUrl, "childToken": childToken, "childName": childName,
    "childSlug": childSlug, "childId": childId, "deviceId": deviceId,
    "balanceEntityId": balanceEntityId, "todayLimitEntityId": todayLimitEntityId,
    "screenTimeSensorId": screenTimeSensorId,
  };

  factory AccountConfig.fromMap(Map<String, String> m) => AccountConfig(
    haUrl: m["haUrl"]!, childToken: m["childToken"]!, childName: m["childName"]!,
    childSlug: m["childSlug"]!, childId: m["childId"]!, deviceId: m["deviceId"]!,
    balanceEntityId: m["balanceEntityId"]!, todayLimitEntityId: m["todayLimitEntityId"]!,
    screenTimeSensorId: m["screenTimeSensorId"]!,
  );
}

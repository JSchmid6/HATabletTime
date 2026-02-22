import "dart:async";
import "dart:convert";
import "package:http/http.dart" as http;
import "package:web_socket_channel/web_socket_channel.dart";

class HaClient {
  final String haUrl;
  final String token;

  HaClient({required this.haUrl, required this.token});

  Map<String, String> get _headers => {
    "Authorization": "Bearer $token",
    "Content-Type": "application/json",
  };

  Future<Map<String, dynamic>> getState(String entityId) async {
    final resp = await http.get(Uri.parse("$haUrl/api/states/$entityId"), headers: _headers);
    if (resp.statusCode != 200) throw HaApiException("GET $entityId => ${resp.statusCode}", resp.body);
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  Future<void> callService(String domain, String service, Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse("$haUrl/api/services/$domain/$service"),
      headers: _headers, body: json.encode(data),
    );
    if (resp.statusCode != 200 && resp.statusCode != 201)
      throw HaApiException("POST $domain/$service => ${resp.statusCode}", resp.body);
  }

  Future<List<Map<String, dynamic>>> getAllStates() async {
    final resp = await http.get(Uri.parse("$haUrl/api/states"), headers: _headers);
    if (resp.statusCode != 200) throw HaApiException("GET /api/states => ${resp.statusCode}", resp.body);
    return (json.decode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Future<void> book({
    required String childSlug, required String childId,
    required String deviceId, required int minutes,
  }) => callService("script", "buche_tabletzeit", {
    "kind": childSlug, "child_id": childId,
    "device_id": deviceId, "minuten": minutes,
  });

  static Future<WsSession> openWebSocket(String haUrl, String adminToken) async {
    final wsUrl = haUrl.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://");
    final channel = WebSocketChannel.connect(Uri.parse("$wsUrl/api/websocket"));
    final session = WsSession(channel);
    await session.authenticate(adminToken);
    return session;
  }
}

class WsSession {
  final WebSocketChannel _channel;
  final StreamController<Map<String, dynamic>> _ctrl = StreamController.broadcast();
  int _nextId = 1;

  WsSession(this._channel) {
    _channel.stream.listen((data) => _ctrl.add(json.decode(data as String) as Map<String, dynamic>));
  }

  Future<void> authenticate(String token) async {
    await _ctrl.stream.firstWhere((m) => m["type"] == "auth_required");
    _channel.sink.add(json.encode({"type": "auth", "access_token": token}));
    final result = await _ctrl.stream.first;
    if (result["type"] != "auth_ok") throw HaApiException("WS auth failed", result.toString());
  }

  Future<Map<String, dynamic>> send(Map<String, dynamic> msg) async {
    final id = _nextId++;
    _channel.sink.add(json.encode({...msg, "id": id}));
    return _ctrl.stream.firstWhere((m) => m["id"] == id);
  }

  Future<void> close() => _channel.sink.close();
}

class HaChild {
  final String name;
  final String childId;
  final String slug;
  final List<HaDevice> devices;
  const HaChild({required this.name, required this.childId, required this.slug, required this.devices});
}

class HaDevice {
  final String deviceId;
  final String displayName;
  final String todayLimitEntityId;
  final String screenTimeSensorId;
  const HaDevice({required this.deviceId, required this.displayName, required this.todayLimitEntityId, required this.screenTimeSensorId});
}

class HaApiException implements Exception {
  final String message;
  final String? body;
  HaApiException(this.message, [this.body]);
  @override
  String toString() => body != null ? "HaApiException: $message\n$body" : "HaApiException: $message";
}
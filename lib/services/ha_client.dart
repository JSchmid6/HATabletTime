import "dart:async";
import "dart:convert";
import "package:flutter/foundation.dart" show debugPrint;
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

  /// Quick check whether [haUrl] points to a real Home Assistant instance.
  /// Returns `null` on success, or an error description on failure.
  static Future<String?> validateHaUrl(String haUrl) async {
    try {
      final resp = await http.get(Uri.parse('$haUrl/api/'),
          headers: {'Content-Type': 'application/json'})
          .timeout(const Duration(seconds: 8));
      // HA returns {"message": "API running."} with 401 (no token) or 200.
      if (resp.statusCode == 200 || resp.statusCode == 401) {
        // Extra check: HA always returns JSON, not HTML.
        final ct = resp.headers['content-type'] ?? '';
        if (ct.contains('text/html') || resp.body.contains('<!DOCTYPE')) {
          return 'Der Server antwortet mit HTML statt JSON.\n'
              'Das ist kein Home Assistant!\n'
              'Prüfe die URL (z.B. http://homeassistant.local:8123).';
        }
        return null; // looks like HA
      }
      if (resp.statusCode == 404) {
        if (resp.body.contains('<!DOCTYPE') || resp.body.contains('<html')) {
          return 'Unter dieser URL läuft kein Home Assistant\n'
              '(Server antwortet mit einer Webseite, nicht der HA-API).\n'
              'Prüfe die URL und den Port (Standard: 8123).';
        }
        return 'Server antwortet mit 404. Prüfe die URL.';
      }
      return 'Unerwarteter Status ${resp.statusCode}.';
    } catch (e) {
      return 'Keine Verbindung: $e';
    }
  }

  Future<Map<String, dynamic>> getState(String entityId) async {
    final resp = await http
        .get(Uri.parse("$haUrl/api/states/$entityId"), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw HaApiException("GET $entityId => ${resp.statusCode}", resp.body);
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  Future<void> callService(String domain, String service, Map<String, dynamic> data) async {
    final url = "$haUrl/api/services/$domain/$service";
    debugPrint('[HaClient] POST $url body=${json.encode(data)}');
    final resp = await http
        .post(Uri.parse(url), headers: _headers, body: json.encode(data))
        .timeout(const Duration(seconds: 10));
    debugPrint('[HaClient] POST $url => ${resp.statusCode} body=${resp.body}');
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw HaApiException("POST $domain/$service => ${resp.statusCode}", resp.body);
    }
  }

  Future<List<Map<String, dynamic>>> getAllStates() async {
    final resp = await http.get(Uri.parse("$haUrl/api/states"), headers: _headers);
    if (resp.statusCode != 200) throw HaApiException("GET /api/states => ${resp.statusCode}", resp.body);
    return (json.decode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  /// Returns all entity registry entries (includes unique_id, platform, entity_id).
  Future<List<Map<String, dynamic>>> getEntityRegistry() async {
    final resp = await http.get(
        Uri.parse("$haUrl/api/config/entity_registry/list"),
        headers: _headers);
    if (resp.statusCode != 200) {
      throw HaApiException("GET /api/config/entity_registry/list => ${resp.statusCode}", resp.body);
    }
    return (json.decode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  /// Returns entity registry entries via WebSocket (more reliable than REST).
  /// Returns the list of entries with unique_id, entity_id, platform etc.
  static Future<List<Map<String, dynamic>>> getEntityRegistryViaWs(
      String haUrl, String token) async {
    final ws = await openWebSocket(haUrl, token);
    try {
      final result = await ws.send({'type': 'config/entity_registry/list'});
      final entries = (result['result'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      return entries;
    } finally {
      await ws.close();
    }
  }

  /// Ensures `input_number.zeitkonto_{slug}` exists in HA.
  ///
  /// Tries to read the entity first; if missing, creates it via the
  /// HA WebSocket API (`input_number/create`).
  /// Returns `true` if the entity was freshly created, `false` if it already
  /// existed.
  Future<bool> ensureBalanceEntity(String slug, String childName) async {
    final entityId = 'input_number.zeitkonto_$slug';
    try {
      await getState(entityId);
      return false; // already exists
    } catch (_) {}
    // Create via WebSocket – HA derives the object_id from the name by slugifying it.
    // "Zeitkonto max_mustermann" → slug "zeitkonto_max_mustermann" → input_number.zeitkonto_max_mustermann
    final ws = await HaClient.openWebSocket(haUrl, token);
    try {
      final result = await ws.send({
        'type': 'input_number/create',
        'name': 'Zeitkonto $slug',
        'min': 0.0,
        'max': 600.0,
        'step': 5.0,
        'mode': 'box',
        'icon': 'mdi:piggy-bank-outline',
      });
      debugPrint('[ensureBalance] WS result: $result');
      if (result['success'] != true) {
        final err = result['error'];
        throw HaApiException(
            'Zeitkonto-Entität konnte nicht erstellt werden: $err', result.toString());
      }
      return true;
    } finally {
      await ws.close();
    }
  }

  /// Books [minutes] for a child by calling `script.tabletzeit_buchen`.
  ///
  /// Matches the script interface defined in the HAFamilyLink integration docs.
  /// Entity-IDs for the FamilyLink entities must be passed from the app's
  /// entity-registry discovery (because HA generates them from device names
  /// and they are not predictable from child_id/device_id alone).
  ///
  /// Variables:
  ///   `kind`             – child slug (e.g. max_mustermann)
  ///   `child_id`         – FamilyLink child_id (opaque Google ID)
  ///   `device_id`        – FamilyLink device_id (opaque device ID)
  ///   `limit_entity_id`  – actual entity_id of TodayLimitNumber (from discovery)
  ///   `sensor_entity_id` – actual entity_id of screen-time sensor (from discovery)
  ///   `minuten`          – positive = buy time, negative = return time
  Future<void> book({
    required String childSlug,
    required String childId,
    required String deviceId,
    required String limitEntityId,
    required String screenTimeSensorId,
    required int minutes,
    required String scriptEntityId,
  }) =>
      callService('script', 'turn_on', {
        'entity_id': scriptEntityId,
        'variables': {
          'kind': childSlug,
          'child_id': childId,
          'device_id': deviceId,
          'limit_entity_id': limitEntityId,
          'sensor_entity_id': screenTimeSensorId,
          'minuten': minutes,
        },
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

  /// Returns a short, user-friendly description.
  /// Strips HTML responses and truncates long bodies.
  String get userMessage {
    if (body == null || body!.isEmpty) return message;
    // Detect HTML responses (wrong server, reverse-proxy error, etc.)
    if (body!.trimLeft().startsWith('<!') || body!.trimLeft().startsWith('<html')) {
      return '$message\n(Server antwortet mit HTML — vermutlich kein Home Assistant)';
    }
    // Truncate very long bodies
    final short = body!.length > 300 ? '${body!.substring(0, 300)}…' : body!;
    return '$message\n$short';
  }

  @override
  String toString() => 'HaApiException: $userMessage';
}
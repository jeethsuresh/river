import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

typedef Json = Map<String, dynamic>;
String transactionId() => base64Url
    .encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

class RiverApi extends ChangeNotifier {
  RiverApi({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  final storage = const FlutterSecureStorage();
  String? token;
  Json? user;
  List<Json> groups = [], events = [], recent = [];
  String? selected, error, pairingLabel;
  bool loading = true, busy = false, active = true, again = false;
  Timer? timer;
  static const endpoint = String.fromEnvironment(
    'RIVER_URL',
    defaultValue: 'https://chat.gravitas.cool',
  );
  Uri uri(String path) =>
      kIsWeb ? Uri.base.resolve(path) : Uri.parse('$endpoint$path');
  Future<Json> request(String path, {String method = 'GET', Json? body}) async {
    final r = http.Request(method, uri(path));
    r.headers.addAll({
      'Content-Type': 'application/json',
      'X-Gravitas-CSRF': '1',
      if (!kIsWeb && token != null) 'Authorization': 'Bearer $token',
    });
    if (body != null) r.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(r).timeout(const Duration(seconds: 20)),
    );
    final data = jsonDecode(response.body) as Json;
    if (response.statusCode == 401) {
      user = null;
      groups = [];
      events = [];
      recent = [];
      selected = null;
      notifyListeners();
    }
    if (response.statusCode >= 400) {
      throw Exception(
        data['error'] ?? 'Request failed (${response.statusCode})',
      );
    }
    return data;
  }

  Future<void> boot() async {
    if (!kIsWeb) token = await storage.read(key: 'river_session');
    try {
      final data = await request('/api/session');
      user = data['user'] as Json;
      await refresh();
    } catch (e) {
      if (user != null) error = '$e';
    }
    loading = false;
    notifyListeners();
    timer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (active && user != null && !busy) unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (busy) {
      again = true;
      return;
    }
    busy = true;
    final account = user?['sub'];
    try {
      final result = await request('/api/groups');
      if (account != user?['sub']) return;
      groups = (result['groups'] as List).cast<Json>();
      if (selected != null && !groups.any((g) => g['id'] == selected)) {
        selected = null;
        events = [];
      }
      final selectedId = selected;
      if (selectedId != null &&
          groups.any(
            (g) => g['id'] == selectedId && g['membership'] == 'join',
          )) {
        final data = await request('/api/groups/$selected/events');
        if (account == user?['sub'] && selectedId == selected) {
          events = (data['events'] as List).cast<Json>();
        }
      } else if (selectedId == null) {
        final collected = <Json>[];
        for (final g in groups
            .where((g) => g['membership'] == 'join')
            .take(12)) {
          final data = await request('/api/groups/${g['id']}/events?limit=30');
          for (final e in (data['events'] as List).cast<Json>()) {
            collected.add({...e, 'group_id': g['id'], 'group_name': g['name']});
          }
        }
        collected.sort(
          (a, b) => (b['origin_server_ts'] as int).compareTo(
            a['origin_server_ts'] as int,
          ),
        );
        if (account == user?['sub']) recent = collected;
      }
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
      if (again && user != null) {
        again = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> open(String? id) async {
    selected = id;
    events = [];
    notifyListeners();
    await refresh();
  }

  Future<void> login() async {
    if (kIsWeb) {
      await launchUrl(uri('/auth/gravitas/start'), webOnlyWindowName: '_self');
      return;
    }
    final verifier = transactionId() + transactionId();
    final proof = verifier.substring(0, 43);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(proof)).bytes)
        .replaceAll('=', '');
    final pair = await request(
      '/api/native/new',
      method: 'POST',
      body: {'challenge': challenge},
    );
    pairingLabel = pair['label'] as String;
    notifyListeners();
    await launchUrl(
      Uri.parse(pair['url'] as String),
      mode: LaunchMode.externalApplication,
    );
    try {
      for (var attempt = 0; attempt < 150; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final result = await request(
          '/api/native/session',
          method: 'POST',
          body: {'id': pair['id'], 'verifier': proof},
        );
        if (result['session'] != null) {
          token = result['session'] as String;
          await storage.write(key: 'river_session', value: token);
          await boot();
          return;
        }
      }
      throw Exception('Device link expired. Start sign-in again.');
    } finally {
      pairingLabel = null;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (kIsWeb) {
      await request('/auth/logout', method: 'POST');
    } else {
      token = null;
      await storage.delete(key: 'river_session');
    }
    user = null;
    groups = [];
    events = [];
    recent = [];
    selected = null;
    notifyListeners();
    if (kIsWeb) await launchUrl(uri('/?auto=off'), webOnlyWindowName: '_self');
  }

  Future<void> create(String name, String kind) async {
    final result = await request(
      '/api/groups',
      method: 'POST',
      body: {'name': name, 'kind': kind, 'txn_id': transactionId()},
    );
    selected = result['id'] as String;
    await refresh();
  }

  Future<void> membership(String id, String action, [String? userId]) async {
    await request(
      '/api/groups/$id/membership',
      method: 'POST',
      body: {'action': action, if (userId != null) 'user_id': userId},
    );
    await refresh();
  }

  Future<void> send(String id, String type, Json content, String txn) async {
    await request(
      '/api/groups/$id/events/$type/$txn',
      method: 'PUT',
      body: {'content': content},
    );
    await refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    client.close();
    super.dispose();
  }
}

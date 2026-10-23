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

class ApiException implements Exception {
  ApiException(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => switch (code) {
    'insufficient_scope' =>
      'Reconnect with Gravitas to approve the new permissions.',
    'forbidden' => 'You no longer have permission for this action.',
    'invalid_membership' =>
      'This request has already changed. Refresh and try again.',
    'transaction_conflict' => 'This action has changed. Please try again.',
    'invalid_member' ||
    'invalid_request' => 'Check the name or person and try again.',
    'too_many_requests' => 'Too many requests. Please try again later.',
    'session_changed' => 'Your account changed. Please try again.',
    _ =>
      status == 401
          ? 'Please sign in again.'
          : 'Unable to connect. Please try again.',
  };
}

class RiverApi extends ChangeNotifier {
  RiverApi({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  final storage = const FlutterSecureStorage();
  String? token;
  Json? user;
  List<Json> groups = [],
      events = [],
      recent = [],
      friends = [],
      requests = [],
      blocked = [];
  String? friendsError, nextCursor;
  int? friendsStatus;
  bool loadingOlder = false;
  int _generation = 0;
  bool _disposed = false;
  final _transactions = <String, String>{};
  final _read = <String, String>{};

  Iterable<Json> get spaces =>
      groups.where((g) => g['kind'] != 'dm' && g['kind'] != 'channel');
  Iterable<Json> channels(String parent) =>
      groups.where((g) => g['parent_id'] == parent);
  int get incomingRequests =>
      requests.where((r) => r['direction'] == 'incoming').length;
  void _clear() {
    groups = [];
    events = [];
    recent = [];
    friends = [];
    requests = [];
    blocked = [];
    selected = null;
    nextCursor = null;
    friendsError = null;
    friendsStatus = null;
    _transactions.clear();
    _read.clear();
  }

  void _expired() {
    _generation++;
    user = null;
    token = null;
    _clear();
    if (!kIsWeb) unawaited(storage.delete(key: 'river_session'));
    notifyListeners();
  }

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
    final generation = _generation;
    final account = user?['sub'];
    final r = http.Request(method, uri(path));
    r.headers.addAll({
      'Content-Type': 'application/json',
      'X-Gravitas-CSRF': '1',
      if (!kIsWeb && token != null) 'Authorization': 'Bearer $token',
    });
    if (body != null) r.body = jsonEncode(body);
    final response = await client
        .send(r)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 20));
    if (generation != _generation || account != user?['sub']) {
      throw ApiException(409, 'session_changed');
    }
    Json data;
    try {
      data = jsonDecode(response.body) as Json;
    } catch (_) {
      throw ApiException(502, 'invalid_response');
    }
    if (response.statusCode == 401) _expired();
    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        data['error'] as String? ?? 'unavailable',
      );
    }
    return data;
  }

  Future<void> boot() async {
    if (!kIsWeb) token = await storage.read(key: 'river_session');
    try {
      final data = await request('/api/session');
      final next = data['user'] as Json;
      if (user?['sub'] != next['sub']) _clear();
      user = next;
      await refresh();
    } catch (e) {
      if (user != null) error = '$e';
    }
    loading = false;
    notifyListeners();
    timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
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
      final result = await request('/api/overview');
      if (account != user?['sub']) return;
      groups = (result['groups'] as List).cast<Json>();
      recent = (result['recent'] as List).cast<Json>();
      if (selected != null && !groups.any((g) => g['id'] == selected)) {
        selected = null;
        events = [];
        nextCursor = null;
      }
      try {
        final social = await request('/api/friends');
        if (account != user?['sub']) return;
        friends = (social['friends'] as List).cast<Json>();
        requests = (social['requests'] as List).cast<Json>();
        blocked = (social['blocked'] as List).cast<Json>();
        friendsError = null;
        friendsStatus = null;
      } on ApiException catch (e) {
        if (account != user?['sub']) return;
        friendsError = '$e';
        friendsStatus = e.status;
        if (e.status == 403) {
          friends = [];
          requests = [];
          blocked = [];
        }
      }
      final selectedId = selected;
      if (selectedId != null &&
          groups.any(
            (g) => g['id'] == selectedId && g['membership'] == 'join',
          )) {
        final data = await request('/api/groups/$selectedId/events');
        if (account == user?['sub'] && selectedId == selected) {
          final latest = (data['events'] as List).cast<Json>();
          final initial = events.isEmpty;
          final overlap = latest.any(
            (e) => events.any((old) => old['event_id'] == e['event_id']),
          );
          _mergeEvents(latest);
          if (initial || (!overlap && latest.isNotEmpty)) {
            nextCursor = data['next_cursor'] as String?;
          }
        }
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
    nextCursor = null;
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
    _expired();
    if (kIsWeb) await launchUrl(uri('/?auto=off'), webOnlyWindowName: '_self');
  }

  Future<void> create(String name, String kind) async {
    final result = await request(
      '/api/groups',
      method: 'POST',
      body: {
        'name': name,
        'kind': kind,
        'txn_id': _transactions.putIfAbsent(
          'create:$name:$kind',
          transactionId,
        ),
      },
    );
    _transactions.remove('create:$name:$kind');
    selected = result['id'] as String;
    events = [];
    nextCursor = null;
    await refresh();
    if (kind == 'space') {
      final lobby =
          channels(
            selected!,
          ).where((c) => c['channel_kind'] == 'text').firstOrNull;
      if (lobby != null) await open(lobby['id'] as String);
    }
  }

  void _mergeEvents(List<Json> incoming) {
    final merged = <String, Json>{
      for (final e in events) e['event_id'] as String: e,
    };
    for (final e in incoming) {
      merged[e['event_id'] as String] = e;
    }
    events =
        merged.values.toList()..sort((a, b) {
          final ax =
              (a['unsigned'] as Json?)?['cool.gravitas.stream_order']
                  as String?;
          final bx =
              (b['unsigned'] as Json?)?['cool.gravitas.stream_order']
                  as String?;
          if (ax != null && bx != null) return ax.compareTo(bx);
          final t = (a['origin_server_ts'] as int).compareTo(
            b['origin_server_ts'] as int,
          );
          return t == 0
              ? (a['event_id'] as String).compareTo(b['event_id'] as String)
              : t;
        });
  }

  Future<void> older() async {
    final cursor = nextCursor, room = selected, account = user?['sub'];
    if (cursor == null || room == null || loadingOlder) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final data = await request(
        '/api/groups/$room/events?before=${Uri.encodeQueryComponent(cursor)}',
      );
      if (account == user?['sub'] && room == selected) {
        _mergeEvents((data['events'] as List).cast<Json>());
        nextCursor = data['next_cursor'] as String?;
      }
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  Future<void> markRead(String room, String event) async {
    if (_read[room] == event) return;
    final account = user?['sub'];
    _read[room] = event;
    try {
      await request(
        '/api/groups/$room/read',
        method: 'POST',
        body: {'event_id': event},
      );
      if (account == user?['sub'] &&
          selected == room &&
          events.lastOrNull?['event_id'] == event) {
        for (final g in groups.where((g) => g['id'] == room)) {
          g['unread_count'] = 0;
        }
        notifyListeners();
      }
    } catch (_) {
      if (_read[room] == event) _read.remove(room);
      rethrow;
    }
  }

  Future<void> createChannel(String parent, String name, String kind) async {
    final key = 'channel:$parent:$name:$kind';
    final result = await request(
      '/api/groups/$parent/channels',
      method: 'POST',
      body: {
        'name': name,
        'kind': kind,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    selected = result['id'] as String;
    events = [];
    nextCursor = null;
    await refresh();
  }

  String userId(String value) {
    final v = value.trim().toLowerCase();
    if (v.startsWith('@') && v.contains(':')) return v;
    final domain =
        user?['domain'] as String? ??
        (user?['user_id'] as String?)?.split(':').skip(1).join(':') ??
        'gravitas.cool';
    return '@${v.replaceFirst(RegExp(r'^@'), '')}:$domain';
  }

  Future<void> friendAction(String person, String action) async {
    final id = userId(person), key = 'friend:$action:$person';
    await request(
      '/api/friends',
      method: 'POST',
      body: {
        'user_id': id,
        'action': action,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    await refresh();
  }

  Future<void> messageFriend(String person) async {
    final result = await request(
      '/api/direct',
      method: 'POST',
      body: {'user_id': userId(person)},
    );
    await open(result['id'] as String);
  }

  Future<Json> thread(String room, String event, {String? before}) => request(
    '/api/groups/$room/thread?event_id=${Uri.encodeQueryComponent(event)}${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}',
  );

  Future<void> react(
    String room,
    String event,
    String emoji,
    bool active,
  ) async {
    final key = 'reaction:$room:$event:$emoji:$active';
    await request(
      '/api/groups/$room/reactions',
      method: 'POST',
      body: {
        'event_id': event,
        'key': emoji,
        'active': active,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    await refresh();
  }

  Future<void> editEntry(
    String room,
    String event,
    String title,
    String body,
  ) async {
    final key = 'edit:$room:$event:$title:$body';
    await request(
      '/api/groups/$room/entry',
      method: 'POST',
      body: {
        'event_id': event,
        'title': title,
        'body': body,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    await refresh();
  }

  Future<void> membership(String id, String action, [String? person]) async {
    await request(
      '/api/groups/$id/membership',
      method: 'POST',
      body: {'action': action, if (person != null) 'user_id': userId(person)},
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
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    timer?.cancel();
    client.close();
    super.dispose();
  }
}

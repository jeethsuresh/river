import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'live_updates.dart';
import 'calls.dart';
import 'peer_files.dart';
import 'file_models.dart' show FileScope;

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
  RiverApi({http.Client? client, bool? live})
    : client = client ?? http.Client(),
      liveEnabled = live ?? client == null;
  final bool liveEnabled;
  LiveUpdates? _live;
  final changes = StreamController<void>.broadcast();
  Set<String> online = {};
  PeerFiles? files;
  RiverCalls? _calls;
  RiverCalls get calls => _calls ??= RiverCalls(this);
  List<Json> activeCalls = [];
  final http.Client client;
  final storage = const FlutterSecureStorage();
  String defaultDomain = const String.fromEnvironment(
    'GRAVITAS_IDENTITY_DOMAIN',
    defaultValue: 'gravitas.cool',
  );
  String? token;
  Json? user;
  String? get accountKey =>
      user == null ? null : "${user?['issuer']}|${user?['sub']}";
  List<Json> groups = [],
      events = [],
      recent = [],
      friends = [],
      otherContacts = [],
      requests = [],
      blocked = [],
      catchUp = [],
      threads = [];
  String? friendsError, nextCursor;
  int? friendsStatus;
  bool loadingOlder = false;
  int _generation = 0;
  bool _disposed = false;
  final _transactions = <String, String>{};
  final _read = <String, String>{};

  Iterable<Json> get spaces => groups.where(
    (g) =>
        g['kind'] != 'dm' &&
        g['kind'] != 'group' &&
        g['kind'] != 'channel' &&
        g['kind'] != 'post_comments' &&
        g['kind'] != 'call_chat',
  );
  Iterable<Json> channels(String parent) =>
      groups.where((g) => g['parent_id'] == parent);
  int get incomingRequests =>
      requests.where((r) => r['direction'] == 'incoming').length;
  void _clear() {
    _live?.close();
    _live = null;
    unawaited(_calls?.leave());
    activeCalls = [];
    final oldFiles = files;
    files = null;
    if (oldFiles != null) {
      unawaited(oldFiles.close().then((_) => oldFiles.dispose()));
    }
    online = {};
    groups = [];
    events = [];
    recent = [];
    catchUp = [];
    threads = [];
    friends = [];
    otherContacts = [];
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
  bool loading = true, busy = false, _active = true, again = false;
  Completer<void>? _queuedRefresh;
  bool get active => _active;
  set active(bool value) {
    _active = value;
    files?.setActive(value);
    if (!value) {
      _live?.close();
      _live = null;
    } else if (user != null) {
      startLive();
      unawaited(refresh());
    }
  }

  void startLive() {
    if (!liveEnabled || !active || _live != null || user == null) return;
    _live = LiveUpdates(
      url: uri('/api/live'),
      headers: () => {
        if (!kIsWeb && token != null) 'Authorization': 'Bearer $token',
      },
      changed: () {
        if (active && user != null) {
          changes.add(null);
          unawaited(refresh());
        }
      },
      revoked: _expired,
    );
    unawaited(_live!.connect());
  }

  Timer? timer;
  static const endpoint = String.fromEnvironment(
    'RIVER_URL',
    defaultValue: 'https://chat.gravitas.cool',
  );
  Uri uri(String path) =>
      kIsWeb ? Uri.base.resolve(path) : Uri.parse('$endpoint$path');
  Future<Json> request(String path, {String method = 'GET', Json? body}) async {
    final generation = _generation;
    final account = accountKey;
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
    if (generation != _generation || account != accountKey) {
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
      final config = await request('/auth/gravitas/config');
      if (config['defaultDomain'] is String) {
        defaultDomain = config['defaultDomain'] as String;
      }
    } catch (_) {}
    try {
      final data = await request('/api/session');
      final next = data['user'] as Json;
      if (accountKey != "${next['issuer']}|${next['sub']}") _clear();
      user = next;
      if (liveEnabled && files == null) {
        final nextFiles = await PeerFiles.create(this, uri('/'), accountKey!);
        if (accountKey == "${next['issuer']}|${next['sub']}") {
          files = nextFiles;
        } else {
          await nextFiles.close();
          nextFiles.dispose();
        }
      }
      await refresh();
    } catch (e) {
      if (user != null) error = '$e';
    }
    loading = false;
    notifyListeners();
    startLive();
  }

  Future<void> refresh() async {
    if (busy) {
      again = true;
      // A mutation can finish while an older read is still in flight. Its
      // caller must wait for the queued fresh read, rather than use old state.
      return (_queuedRefresh ??= Completer<void>()).future;
    }
    busy = true;
    final account = accountKey;
    try {
      final result = await request('/api/overview');
      if (account != accountKey) return;
      groups = (result['groups'] as List).cast<Json>();
      await files?.setScopes([
        for (final g in groups.where((g) => g['membership'] == 'join'))
          FileScope('room', g['id'] as String),
      ], active: active);
      recent = (result['recent'] as List).cast<Json>();
      if (liveEnabled) {
        final home = await request('/api/home');
        catchUp = ((home['catch_up'] as List?) ?? []).cast<Json>();
        threads = ((home['threads'] as List?) ?? []).cast<Json>();
        final entries = ((home['recent_entries'] as List?) ?? []).cast<Json>();
        final entryIds = entries.map((e) => e['event_id']).toSet();
        recent = [
          ...entries,
          ...recent.where((e) => !entryIds.contains(e['event_id'])),
        ];
        try {
          activeCalls = ((await request('/api/calls'))['calls'] as List)
              .cast<Json>();
        } on ApiException {
          activeCalls = [];
        }
      }
      if (selected != null && !groups.any((g) => g['id'] == selected)) {
        selected = null;
        events = [];
        nextCursor = null;
      }
      try {
        final social = await request('/api/friends');
        if (account != accountKey) return;
        friends = (social['friends'] as List).cast<Json>();
        otherContacts = ((social['other_contacts'] as List?) ?? [])
            .cast<Json>();
        requests = (social['requests'] as List).cast<Json>();
        blocked = (social['blocked'] as List).cast<Json>();
        friendsError = null;
        friendsStatus = null;
      } on ApiException catch (e) {
        if (account != accountKey) return;
        friendsError = '$e';
        friendsStatus = e.status;
        if (e.status == 403) {
          friends = [];
          otherContacts = [];
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
        if (account == accountKey && selectedId == selected) {
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
      if (liveEnabled) {
        try {
          final presence = await request('/api/presence');
          online = ((presence['online'] as List?) ?? []).cast<String>().toSet();
        } on ApiException catch (e) {
          if (e.status == 403) online = {};
        }
      }
      error = null;
    } catch (e) {
      error = '$e';
    } finally {
      final queued = _queuedRefresh;
      _queuedRefresh = null;
      busy = false;
      if (again && user != null) {
        again = false;
        // Start before notifying listeners so another request cannot overtake
        // this queued pass. Each waiter finishes after its pass, even if more
        // invalidations arrive while that pass runs.
        unawaited(refresh().whenComplete(() => queued?.complete()));
      } else {
        again = false;
        queued?.complete();
      }
      notifyListeners();
    }
  }

  Future<void> open(String? id) async {
    selected = id;
    events = [];
    nextCursor = null;
    notifyListeners();
    await refresh();
  }

  Future<void> login({
    String? next,
    String? username,
    bool register = false,
  }) async {
    if (!register) username ??= user?['user_id'] as String?;
    if (kIsWeb) {
      await launchUrl(
        uri(
          Uri(
            path: register ? '/auth/gravitas/register' : '/auth/gravitas/start',
            queryParameters: {
              if (next != null) 'next': next,
              if (username != null) 'username': username,
            },
          ).toString(),
        ),
        webOnlyWindowName: '_self',
      );
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
      body: {
        'challenge': challenge,
        if (username != null) 'username': username,
        if (register) 'register': true,
      },
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
      final lobby = channels(
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
    events = merged.values.toList()
      ..sort((a, b) {
        final ax =
            (a['unsigned'] as Json?)?['cool.gravitas.stream_order'] as String?;
        final bx =
            (b['unsigned'] as Json?)?['cool.gravitas.stream_order'] as String?;
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
    final cursor = nextCursor, room = selected, account = accountKey;
    if (cursor == null || room == null || loadingOlder) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final data = await request(
        '/api/groups/$room/events?before=${Uri.encodeQueryComponent(cursor)}',
      );
      if (account == accountKey && room == selected) {
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
    final account = accountKey;
    _read[room] = event;
    try {
      await request(
        '/api/groups/$room/read',
        method: 'POST',
        body: {'event_id': event},
      );
      if (account == accountKey &&
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

  Future<void> conversation(String name, List<String> members) async {
    final key = 'conversation:$name:${members.join(',')}';
    final result = await request(
      '/api/conversations',
      method: 'POST',
      body: {
        'name': name,
        'member_ids': members,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    await open(result['id'] as String);
  }

  Future<void> inviteSpace(String conversation, String space) async {
    final key = 'invite:$conversation:$space';
    await request(
      '/api/groups/$conversation/invitations',
      method: 'POST',
      body: {
        'space_id': space,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    await refresh();
  }

  Future<void> readEntry(String room, String event) async {
    await request(
      '/api/groups/$room/entry/read',
      method: 'POST',
      body: {'event_id': event},
    );
    catchUp.removeWhere((e) => e['event_id'] == event);
    notifyListeners();
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
    String body, {
    bool refreshAfter = true,
  }) async {
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
    if (refreshAfter) await refresh();
  }

  Future<void> membership(String id, String action, [String? person]) async {
    await request(
      '/api/groups/$id/membership',
      method: 'POST',
      body: {'action': action, if (person != null) 'user_id': userId(person)},
    );
    await refresh();
  }

  Future<Json> send(
    String id,
    String type,
    Json content,
    String txn, {
    bool refreshAfter = true,
  }) async {
    final result = await request(
      '/api/groups/$id/events/$type/$txn',
      method: 'PUT',
      body: {'content': content},
    );
    if (refreshAfter) await refresh();
    return result;
  }

  Future<Json> publicPost(String event, {String? before}) => request(
    '/api/public/posts/${Uri.encodeComponent(event)}${before == null ? '' : '?before=${Uri.encodeQueryComponent(before)}'}',
  );
  Future<Json> blog(String room, {String? before}) => request(
    '/api/public/spaces/$room/posts${before == null ? '' : '?before=${Uri.encodeQueryComponent(before)}'}',
  );
  Future<void> publication(
    String room,
    String event,
    String visibility,
    String comments, {
    bool refreshAfter = true,
  }) async {
    final key = 'publish:$room:$event:$visibility:$comments';
    await request(
      '/api/groups/$room/publication',
      method: 'POST',
      body: {
        'event_id': event,
        'visibility': visibility,
        'comments_policy': comments,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    if (refreshAfter) await refresh();
  }

  Future<void> postComment(
    String event,
    String body,
    String txn, {
    String? parent,
    required String audience,
  }) async {
    await request(
      '/api/posts/${Uri.encodeComponent(event)}/comment',
      method: 'POST',
      body: {
        'body': body,
        'audience': audience,
        'txn_id': txn,
        if (parent != null) 'parent_id': parent,
      },
    );
    await refresh();
  }

  Future<void> postReaction(String event, String emoji, bool active) async {
    final key = 'public-reaction:$event:$emoji:$active';
    await request(
      '/api/posts/${Uri.encodeComponent(event)}/reactions',
      method: 'POST',
      body: {
        'key': emoji,
        'active': active,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
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
    _live?.close();
    _calls?.dispose();
    final oldFiles = files;
    if (oldFiles != null) {
      unawaited(oldFiles.close().then((_) => oldFiles.dispose()));
    }
    changes.close();
    client.close();
    super.dispose();
  }
}

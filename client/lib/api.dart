import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'live_updates.dart';
import 'performance.dart';
import 'connection_health.dart';
import 'matrix_messaging.dart';
import 'matrix_timeline.dart';
import 'calls.dart';
import 'peer_files.dart';
import 'media.dart' show LinkedImageCache;
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
  RiverApi({
    http.Client? client,
    bool? live,
    MatrixFactory? matrixFactory,
    MatrixStorage? matrixStorage,
    bool? matrixEnabled,
    this.authLaunch,
  }) : client = client ?? http.Client(),
       liveEnabled = live ?? client == null,
       matrixEnabled = matrixEnabled ?? (live ?? client == null),
       _matrixFactory = matrixFactory,
       _matrixStorage = matrixStorage;
  final bool liveEnabled;
  final bool matrixEnabled;
  final Future<bool> Function(Uri)? authLaunch;
  Future<void>? _nativeExchange;
  bool _signingIn = false;
  final MatrixFactory? _matrixFactory;
  final MatrixStorage? _matrixStorage;
  MatrixMessaging? _matrix;
  MatrixMessaging get matrix => _matrix ??= (MatrixMessaging(
    request: request,
    factory: _matrixFactory,
    storage: _matrixStorage,
    syncEnabled: liveEnabled,
    changed: () {
      if (!_disposed && !_restoringLocal && user != null && active) {
        changes.add(null);
        groups = _matrixGroups(groups);
        if (selected != null &&
            !groups.any(
              (g) => g['id'] == selected && g['membership'] == 'join',
            )) {
          _selectionRevision++;
          selected = null;
          _matrixEvents = [];
          _pendingEchoes.clear();
          events = [];
          nextCursor = null;
        }
        unawaited(
          _loadSelected().catchError((Object e) {
            error = _backgroundError(e);
            notifyListeners();
          }),
        );
        notifyListeners();
      }
    },
  )..addListener(notifyListeners));
  final MatrixStorage _fallbackIdentity = const SecureMatrixStorage();
  MatrixStorage get _identity => _matrixStorage ?? _fallbackIdentity;
  bool _restoringLocal = false, _offlineSession = false;
  late final _apiConnection = ConnectionHealth(notifyListeners);
  bool get reconnecting =>
      _apiConnection.retrying || (_matrix?.reconnecting ?? false);
  bool get networkUnavailable =>
      (_offlineSession && _apiConnection.retrying) ||
      _apiConnection.unavailable ||
      (_matrix?.networkUnavailable ?? false);
  bool get readOnly => _offlineSession || (_matrix?.reconnecting ?? false);
  String? get connectionWarning {
    if (_offlineSession && _apiConnection.retrying) {
      return 'Network unavailable';
    }
    final api = _apiConnection.unavailable;
    final messaging = _matrix?.networkUnavailable ?? false;
    if (api && messaging) return 'River and Matrix messaging are reconnecting…';
    if (messaging) return 'Matrix messaging is reconnecting…';
    if (api) return 'River is reconnecting…';
    return null;
  }

  Future<void> retryConnections() async {
    await Future.wait<void>([
      refresh(),
      if (matrixConnected)
        matrix.syncNow().catchError((Object e) {
          if (!matrixNetworkFailure(e)) throw e;
        }),
    ]);
  }

  String? cacheError;
  final _cacheFailures = <String>{};
  int _historyRevision = 0;
  LinkedImageCache? linkedImages;

  void requireNetwork() {
    // Cached startup credentials need fresh authorization before any write.
    // An already validated session may retry a failed operation to probe recovery.
    if (_offlineSession) {
      throw StateError('Network unavailable. Reconnect to make changes.');
    }
  }

  String? _backgroundError(Object error) {
    final transportFailure =
        error is http.ClientException ||
        error is TimeoutException ||
        matrixNetworkFailure(error) ||
        (error is ApiException && [502, 503, 504].contains(error.status));
    return transportFailure ? null : '$error';
  }

  Future<void> _saveLocal(
    String scope,
    Json? value, {
    String? room,
    String? event,
  }) async {
    if (!matrixConnected) return;
    final account = accountKey;
    try {
      await matrix.writeLocal(scope, value, room: room, event: event);
      if (account == accountKey) {
        _cacheFailures.remove('$scope:$room:$event');
        if (_cacheFailures.isEmpty) cacheError = null;
      }
    } catch (_) {
      if (account == accountKey) {
        _cacheFailures.add('$scope:$room:$event');
        cacheError =
            'Changes could not be saved on this device. Check available storage.';
        notifyListeners();
      }
    }
  }

  Future<Json?> draft(String room) =>
      matrixConnected ? matrix.readLocal('draft', room: room) : Future.value();
  Future<void> saveDraft(String room, Json? value) =>
      _saveLocal('draft', value, room: room);

  Future<void> _saveOverview() => _saveLocal('overview', {
    'groups': groups,
    'recent': recent,
    'selected': selected,
  });

  Future<void> _saveHistory(String id) async {
    final wire = matrixRoom(id);
    if (!matrixConnected || wire == null) return;
    await _saveLocal('history', {
      'events': _matrixEvents,
      'next_cursor': nextCursor,
    }, room: wire);
  }

  Future<void> _loadHistory(String id) async {
    final wire = matrixRoom(id), account = accountKey;
    final revision = _historyRevision;
    if (!matrixConnected ||
        wire == null ||
        group(id)?['membership'] != 'join' ||
        !matrix.roomList.any(
          (room) => room['room_id'] == wire && room['membership'] == 'join',
        )) {
      return;
    }
    final cached = await matrix.readLocal('history', room: wire);
    if (cached != null &&
        account == accountKey &&
        selected == id &&
        revision == _historyRevision) {
      _mergeEvents((cached['events'] as List).cast<Json>());
      nextCursor = cached['next_cursor'] as String?;
      notifyListeners();
    }
  }

  Future<void> _initializeFiles() async {
    if (!liveEnabled || files != null || user == null) return;
    final account = accountKey;
    final next = await PeerFiles.create(this, uri('/'), account!);
    if (account != accountKey) {
      next.dispose();
      return;
    }
    files = next;
    linkedImages = LinkedImageCache(next.cache.store);
  }

  Future<void> _rememberIdentity() async {
    if (matrixEnabled && user != null) {
      final snapshot = jsonEncode({'origin': uri('/').origin, 'profile': user});
      final generation = _generation;
      await _sessionStorage(() async {
        if (generation == _generation && user != null) {
          await _identity.write('river.offline_profile', snapshot);
        }
      });
    }
  }

  Future<void> _restoreLocal() async {
    if (!matrixEnabled) return;
    _restoringLocal = true;
    final generation = _generation;
    try {
      final saved = await _identity.read('river.offline_profile');
      if (saved == null || generation != _generation) return;
      final record = jsonDecode(saved) as Json;
      final profile = record['profile'] as Json;
      if (record['origin'] != uri('/').origin ||
          profile['issuer'] is! String ||
          profile['sub'] is! String ||
          profile['user_id'] is! String) {
        return;
      }
      user = profile;
      _offlineSession = true;
      await matrix.bind(profile, synchronize: false);
      if (!matrixConnected) {
        user = null;
        return;
      }
      final cached = await matrix.readLocal('overview');
      if (generation != _generation) return;
      groups = _matrixGroups(((cached?['groups'] as List?) ?? []).cast<Json>());
      recent = ((cached?['recent'] as List?) ?? []).cast<Json>();
      selected = cached?['selected'] as String?;
      if (!groups.any((g) => g['id'] == selected)) selected = null;
      await _initializeFiles();
      if (selected != null) await _loadHistory(selected!);
      loading = false;
      notifyListeners();
    } catch (_) {
      // A broken local record must not prevent normal online sign-in.
      if (generation == _generation) {
        cacheError = 'Some saved data could not be opened on this device.';
      }
    } finally {
      if (generation == _generation && user != null && matrixConnected) {
        loading = false;
        notifyListeners();
      }
      _restoringLocal = false;
    }
  }

  bool get matrixConnected => _matrix?.connected ?? false;
  Json? group(String id) => groups.where((g) => g['id'] == id).firstOrNull;
  String displayName(String id) {
    final people = <Json>[
      if (user != null) user!,
      ...friends,
      ...otherContacts,
      for (final g in groups) ...(g['members'] as List? ?? []).cast<Json>(),
    ];
    for (final person in people) {
      if (person['user_id'] == id || person['username'] == id) {
        final name =
            person['display_name'] ??
            person['displayname'] ??
            person['name'] ??
            person['username'];
        if (name is String && name.isNotEmpty && !name.startsWith('@')) {
          return name;
        }
      }
    }
    final local = id.startsWith('@') ? id.substring(1).split(':').first : id;
    return local.replaceAll(RegExp(r'[._]'), ' ');
  }

  String get _favouritesKey =>
      'river.favourites.${sha256.convert(utf8.encode(accountKey ?? ''))}';
  Future<Set<String>> favouritePeople() async {
    final value = await _identity.read(_favouritesKey);
    return value == null
        ? <String>{}
        : (jsonDecode(value) as List).cast<String>().toSet();
  }

  Future<void> saveFavouritePeople(Set<String> people) =>
      _identity.write(_favouritesKey, jsonEncode(people.toList()..sort()));

  String? matrixRoom(String id) => group(id)?['room_id'] as String?;
  bool encrypted(String id) => group(id)?['encrypted'] == true;

  void requireSpace(String id) {
    if (group(id)?['kind'] != 'space') {
      throw StateError('Posts and discussions belong to a space.');
    }
  }

  List<Json> _matrixGroups(List<Json> delegated) {
    if (!matrixConnected) return delegated;
    final byWire = <String, Json>{
      for (final g in delegated)
        if (g['room_id'] is String) g['room_id'] as String: g,
    };
    for (final room in matrix.roomList) {
      final wire = room['room_id'] as String;
      final old = byWire[wire];
      if (!['join', 'invite', 'knock'].contains(room['membership'])) {
        byWire.remove(wire);
        continue;
      }
      byWire[wire] = {
        if (old != null) ...old,
        'id': old?['id'] ?? wire,
        'room_id': wire,
        'name': room['name'],
        'description': room['description'] ?? old?['description'] ?? '',
        'channel_kind': room['channel_kind'] ?? old?['channel_kind'],
        'membership': room['membership'],
        'kind': old?['kind'] ?? room['kind'],
        'members': old?['members'] ?? <Json>[],
        'owner_id': room['can_manage'] == true ? (user?['sub']) : null,
        'owner': room['can_manage'] == true,
        'can_manage': room['can_manage'],
        'can_encrypt': room['can_encrypt'],
        'encrypted': room['encrypted'],
        'unread_count': room['unread_count'],
        'matrix_only': old == null,
        'matrix_parents': room['parents'] ?? [],
      };
    }
    for (final room in byWire.values) {
      final parents = room['matrix_parents'] as List? ?? [];
      final parentId = parents
          .where((p) => byWire[p]?['kind'] == 'space')
          .firstOrNull;
      if (parentId != null && room['kind'] != 'space') {
        final parent = byWire[parentId]!;
        room['parent_id'] = parent['id'];
        room['kind'] = 'channel';
        room['channel_kind'] ??= 'text';
      }
    }
    return byWire.values.toList();
  }

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
  List<Json> _matrixEvents = [];
  final _pendingEchoes = <String>{};
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
  int _credentialRevision = 0;
  Future<void>? _renewing;
  Future<void> _sessionStorageQueue = Future.value();
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
    _apiConnection.reset();
    if (_matrix != null) unawaited(_matrix!.disconnect());
    _live?.close();
    _live = null;
    unawaited(_calls?.leave());
    activeCalls = [];
    final oldFiles = files;
    files = null;
    linkedImages = null;
    if (oldFiles != null) {
      unawaited(oldFiles.close().then((_) => oldFiles.dispose()));
    }
    online = {};
    groups = [];
    _matrixEvents = [];
    _pendingEchoes.clear();
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
    _cacheFailures.clear();
    cacheError = null;
  }

  void _expired() {
    unawaited(_sessionStorage(() => _identity.delete('river.offline_profile')));
    _offlineSession = false;
    _generation++;
    _credentialRevision++;
    user = null;
    token = null;
    _clear();
    if (!kIsWeb) {
      unawaited(_sessionStorage(() => storage.delete(key: 'river_session')));
    }
    notifyListeners();
  }

  String? selected, error, pairingLabel;
  bool loading = true, busy = false, _active = true, again = false;
  Completer<void>? _queuedRefresh;
  bool get active => _active;
  set active(bool value) {
    final transition = _active != value;
    if (transition) _apiConnection.reset();
    _active = value;
    files?.setActive(value);
    _matrix?.active = value;
    if (!value) {
      _live?.close();
      _live = null;
    } else if (user != null) {
      startLive();
      unawaited(refresh());
    }
    if (transition) notifyListeners();
  }

  void startLive() {
    if (!liveEnabled || !active || _live != null || user == null) return;
    _live = LiveUpdates(
      url: uri('/api/live'),
      prepare: () async {
        await request('/api/session');
      },
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
    if (method != 'GET' &&
        path.startsWith('/api/') &&
        !path.startsWith('/api/native/') &&
        path != '/api/session/refresh') {
      requireNetwork();
    }
    final generation = _generation;
    final revision = _credentialRevision;
    var response = await _send(path, method: method, body: body);
    if (response.statusCode == 401 &&
        path.startsWith('/api/') &&
        !path.startsWith('/api/native/') &&
        path != '/api/session/refresh') {
      if (revision == _credentialRevision) await _renewSession();
      if (generation != _generation) throw ApiException(409, 'session_changed');
      response = await _send(path, method: method, body: body);
    }
    if (response.statusCode == 401 ||
        (path == '/api/session' && response.statusCode == 403)) {
      _expired();
    }
    return _responseData(response);
  }

  Future<void> _sessionStorage(Future<void> Function() operation) {
    final result = _sessionStorageQueue.then((_) => operation());
    _sessionStorageQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _renewSession() async {
    if (_renewing != null) return _renewing!;
    final pending = _performRenewal();
    _renewing = pending;
    try {
      await pending;
    } finally {
      if (identical(_renewing, pending)) _renewing = null;
    }
  }

  Future<void> _performRenewal() async {
    final generation = _generation;
    final response = await _send('/api/session/refresh', method: 'POST');
    if (response.statusCode == 401) _expired();
    final data = _responseData(response);
    if (!kIsWeb) {
      final renewed = data['session'];
      if (renewed is! String || renewed.isEmpty) {
        throw ApiException(502, 'invalid_response');
      }
      await _sessionStorage(() async {
        if (generation != _generation) {
          throw ApiException(409, 'session_changed');
        }
        await storage.write(key: 'river_session', value: renewed);
        if (generation != _generation) {
          throw ApiException(409, 'session_changed');
        }
        token = renewed;
      });
    }
    if (generation != _generation) throw ApiException(409, 'session_changed');
    _credentialRevision++;
  }

  Json _responseData(http.Response response) {
    Json data;
    try {
      data = jsonDecode(response.body) as Json;
    } catch (_) {
      throw ApiException(502, 'invalid_response');
    }
    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        data['error'] as String? ?? 'unavailable',
      );
    }
    return data;
  }

  Future<http.Response> _send(
    String path, {
    String method = 'GET',
    Json? body,
  }) => RiverPerformance.measure(
    'http.$method.${Uri.parse(path).pathSegments.elementAtOrNull(1) ?? "root"}',
    () => _sendUnprofiled(path, method: method, body: body),
  );

  Future<http.Response> _sendUnprofiled(
    String path, {
    String method = 'GET',
    Json? body,
  }) async {
    final generation = _generation;
    final account = accountKey;
    final observation = _apiConnection.begin();
    final r = http.Request(method, uri(path));
    r.headers.addAll({
      'Content-Type': 'application/json',
      'X-Gravitas-CSRF': '1',
      if (!kIsWeb && token != null) 'Authorization': 'Bearer $token',
    });
    if (body != null) r.body = jsonEncode(body);
    late http.Response response;
    try {
      response = await client
          .send(r)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (generation == _generation && account == accountKey) {
        final unavailable = [502, 503, 504].contains(response.statusCode);
        if (unavailable) {
          _apiConnection.failed(observation);
        } else {
          _apiConnection.succeeded(observation);
        }
      }
    } on Object catch (e) {
      if ((e is http.ClientException || e is TimeoutException) &&
          generation == _generation &&
          account == accountKey) {
        _apiConnection.failed(observation);
      }
      rethrow;
    }
    if (generation != _generation || account != accountKey) {
      throw ApiException(409, 'session_changed');
    }
    return response;
  }

  Future<void> _loadLoginConfig() async {
    try {
      final config = await request('/auth/gravitas/config');
      if (config['defaultDomain'] is String) {
        defaultDomain = config['defaultDomain'] as String;
      }
    } catch (_) {}
  }

  Future<void> boot() => RiverPerformance.measure('app.boot', _boot);

  Future<void> _boot() async {
    await _restoreLocal();
    if (!kIsWeb) {
      token = await storage.read(key: 'river_session');
      final pending = await storage.read(key: 'river_native_pending');
      if (pending != null) {
        try {
          await _exchangeNative(
            (jsonDecode(pending) as Map).cast<String, dynamic>(),
          );
        } catch (e) {
          error = '$e';
        }
      }
    }
    unawaited(_loadLoginConfig());
    try {
      final data = await request('/api/session');
      final next = data['user'] as Json;
      if (accountKey != "${next['issuer']}|${next['sub']}") _clear();
      user = next;
      _offlineSession = false;
      await _rememberIdentity();
      if (matrixEnabled) {
        unawaited(
          matrix.bind(next).then((_) {
            if (accountKey == "${next['issuer']}|${next['sub']}") {
              matrix.active = active;
            }
          }),
        );
      }
      await _initializeFiles();
      await refresh();
    } catch (e) {
      if (user != null) error = _backgroundError(e);
    }
    loading = false;
    notifyListeners();
    startLive();
    if (liveEnabled) {
      timer ??= Timer.periodic(const Duration(seconds: 10), (_) {
        if (!_disposed && active && user != null && !busy && reconnecting) {
          unawaited(refresh());
        }
      });
    }
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
      if (_offlineSession) {
        final session = await request('/api/session');
        if (account != accountKey) return;
        final profile = session['user'] as Json;
        if (account != "${profile['issuer']}|${profile['sub']}") {
          _clear();
          user = profile;
          await matrix.bind(profile);
          await _initializeFiles();
        }
        _offlineSession = false;
        await _rememberIdentity();
        if (matrixEnabled) matrix.active = active;
      }
      final result = await request('/api/overview');
      if (account != accountKey) return;
      final selectedWire = selected == null ? null : matrixRoom(selected!);
      groups = _matrixGroups((result['groups'] as List).cast<Json>());
      await _saveOverview();
      // A native Matrix room may subsequently acquire its delegated River ID.
      // Keep the open conversation when that metadata arrives.
      if (selectedWire != null) {
        selected =
            groups.where((g) => g['room_id'] == selectedWire).firstOrNull?['id']
                as String? ??
            selected;
      }
      recent = (result['recent'] as List).cast<Json>();
      if (selected != null && !groups.any((g) => g['id'] == selected)) {
        selected = null;
        _selectionRevision++;
        _matrixEvents = [];
        events = [];
        nextCursor = null;
      }
      // Make the account shell usable as soon as its room list is available.
      loading = false;
      notifyListeners();
      await Future.wait<void>([
        _loadSelected(),
        (() async {
          await files?.setScopes([
            for (final g in groups.where((g) => g['membership'] == 'join'))
              FileScope('room', g['id'] as String),
          ], active: active);
        })(),
        (() async {
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
        })(),
        if (liveEnabled) ...[
          (() async {
            final home = await request('/api/home');
            if (account != accountKey) return;
            catchUp = ((home['catch_up'] as List?) ?? []).cast<Json>();
            threads = ((home['threads'] as List?) ?? []).cast<Json>();
            final entries = ((home['recent_entries'] as List?) ?? [])
                .cast<Json>();
            final entryIds = entries.map((e) => e['event_id']).toSet();
            recent = [
              ...entries,
              ...recent.where((e) => !entryIds.contains(e['event_id'])),
            ];
          })(),
          (() async {
            try {
              final result = await request('/api/calls');
              if (account != accountKey) return;
              activeCalls = (result['calls'] as List).cast<Json>();
            } on ApiException {
              if (account == accountKey) activeCalls = [];
            }
          })(),
          (() async {
            try {
              final presence = await request('/api/presence');
              if (account != accountKey) return;
              online = ((presence['online'] as List?) ?? [])
                  .cast<String>()
                  .toSet();
            } on ApiException catch (e) {
              if (account == accountKey && e.status == 403) online = {};
            }
          })(),
        ],
      ]);
      if (account != accountKey) return;
      await _saveOverview();
      error = null;
    } catch (e) {
      error = _backgroundError(e);
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

  int _selectionRevision = 0;

  Future<void> _loadSelected({bool roster = false}) async {
    final account = accountKey;
    final selectedId = selected;
    final selectionRevision = _selectionRevision;
    if (selectedId != null &&
        groups.any((g) => g['id'] == selectedId && g['membership'] == 'join')) {
      final wire = matrixRoom(selectedId);
      if (matrixConnected && wire != null) {
        await matrix.ensureJoinedRoom(wire);
      }
      final data = matrixConnected && wire != null
          ? await matrix.readNetwork(
              (transport) => transport.history(wire, null),
            )
          : await request('/api/groups/$selectedId/events');
      if (account == accountKey &&
          selectedId == selected &&
          selectionRevision == _selectionRevision) {
        final latest = (data['events'] as List).cast<Json>();
        final initial = events.isEmpty;
        final known = events.map((e) => e['event_id']).toSet();
        final overlap = latest.any((e) => known.contains(e['event_id']));
        _mergeEvents(latest);
        if (initial || (!overlap && latest.isNotEmpty)) {
          nextCursor = data['next_cursor'] as String?;
        }
      }
      notifyListeners();
      if (account == accountKey &&
          selectedId == selected &&
          selectionRevision == _selectionRevision) {
        await _saveHistory(selectedId);
      }
      if (roster && matrixConnected && wire != null) {
        unawaited(_loadRoster(selectedId, wire, account, selectionRevision));
      }
    }
  }

  Future<void> _loadRoster(
    String id,
    String wire,
    String? account,
    int revision,
  ) async {
    try {
      final data = await matrix.transport.members(wire);
      if (account == accountKey &&
          selected == id &&
          revision == _selectionRevision) {
        group(id)?['members'] = data['members'];
        notifyListeners();
      }
    } catch (_) {
      // Timeline availability is independent of optional roster enrichment.
    }
  }

  Future<void> open(String? id) =>
      RiverPerformance.measure('conversation.open', () => _open(id));

  Future<void> _open(String? id) async {
    final revision = ++_selectionRevision;
    _historyRevision++;
    selected = id;
    _matrixEvents = [];
    _pendingEchoes.clear();
    events = [];
    nextCursor = null;
    final account = accountKey;
    try {
      if (id != null) await _loadHistory(id);
      await _saveOverview();
    } catch (_) {
      if (account == accountKey && id == selected) {
        cacheError = 'Some saved messages could not be opened on this device.';
      }
    }
    if (account != accountKey ||
        id != selected ||
        revision != _selectionRevision) {
      return;
    }
    notifyListeners();
    try {
      // New groups need their delegated metadata once. Known conversations can
      // load directly even while a slow account refresh is in flight.
      if (id != null && group(id) == null) await refresh();
      await _loadSelected(roster: true);
      error = null;
    } catch (e) {
      error = _backgroundError(e);
    }
    notifyListeners();
  }

  Future<void> login({
    String? next,
    String? username,
    bool register = false,
  }) async {
    if (_signingIn) return;
    _signingIn = true;
    try {
      await _login(next: next, username: username, register: register);
    } finally {
      _signingIn = false;
    }
  }

  Future<void> _login({
    String? next,
    String? username,
    required bool register,
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
    final pending = <String, dynamic>{
      'id': pair['id'],
      'verifier': proof,
      'label': pair['label'],
      'expires_at': DateTime.now()
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch,
    };
    await _sessionStorage(
      () => storage.write(
        key: 'river_native_pending',
        value: jsonEncode(pending),
      ),
    );
    try {
      final url = Uri.parse(pair['url'] as String);
      final opened =
          await (authLaunch?.call(url) ??
              launchUrl(url, mode: LaunchMode.externalApplication));
      if (!opened) {
        await _sessionStorage(
          () => storage.delete(key: 'river_native_pending'),
        );
        throw StateError('Unable to open sign-in. Please try again.');
      }
      await _exchangeNative(pending);
      await boot();
    } finally {
      pairingLabel = null;
      notifyListeners();
    }
  }

  Future<void> _exchangeNative(Json pending) {
    return _nativeExchange ??= _pollNative(
      pending,
    ).whenComplete(() => _nativeExchange = null);
  }

  Future<void> _pollNative(Json pending) async {
    final generation = _generation;
    pairingLabel = pending['label'] as String?;
    notifyListeners();
    try {
      while (DateTime.now().millisecondsSinceEpoch <
          (pending['expires_at'] as int)) {
        if (generation != _generation || _disposed) {
          throw ApiException(409, 'session_changed');
        }
        final result = await request(
          '/api/native/session',
          method: 'POST',
          body: {'id': pending['id'], 'verifier': pending['verifier']},
        );
        if (result['session'] is String) {
          await _sessionStorage(() async {
            if (generation != _generation || _disposed) {
              throw ApiException(409, 'session_changed');
            }
            await storage.write(
              key: 'river_session',
              value: result['session'] as String,
            );
            if (generation != _generation || _disposed) {
              throw ApiException(409, 'session_changed');
            }
            token = result['session'] as String;
            await storage.delete(key: 'river_native_pending');
          });
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await _sessionStorage(() => storage.delete(key: 'river_native_pending'));
      throw StateError('Device link expired. Start sign-in again.');
    } on ApiException catch (e) {
      if (generation == _generation && (e.status == 400 || e.status == 403)) {
        await _sessionStorage(
          () => storage.delete(key: 'river_native_pending'),
        );
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        pairingLabel = null;
        notifyListeners();
      }
    }
  }

  Future<void> resumeAuthentication() async {
    if (!kIsWeb && _nativeExchange == null) {
      final pending = await storage.read(key: 'river_native_pending');
      if (pending != null) {
        try {
          await _exchangeNative(
            (jsonDecode(pending) as Map).cast<String, dynamic>(),
          );
          await boot();
        } catch (e) {
          error = '$e';
          notifyListeners();
        }
      }
    }
    if (user == null) return;
    if (matrixEnabled && !matrixConnected) {
      await matrix.bind(user!);
    }
    await refresh();
  }

  Future<void> logout() async {
    final renewal = _renewing;
    _generation++;
    if (!kIsWeb) {
      token = null;
      await _sessionStorage(() async {
        await storage.delete(key: 'river_native_pending');
        await storage.delete(key: 'river_session');
        await _identity.delete('river.offline_profile');
      });
    }
    // Browsers apply Set-Cookie before Dart sees the response. Clear the cookie
    // after an in-flight renewal finishes so it cannot undo an explicit logout.
    if (kIsWeb && renewal != null) {
      try {
        await renewal;
      } catch (_) {}
    }
    try {
      await _matrix?.disconnect(logout: true);
    } catch (_) {}
    if (kIsWeb) {
      await request('/auth/logout', method: 'POST');
    } else {
      token = null;
      await _sessionStorage(() => storage.delete(key: 'river_session'));
    }
    _expired();
    await _sessionStorage(() => _identity.delete('river.offline_profile'));
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
    if (matrixConnected) await matrix.syncNow();
    await open(result['id'] as String);
    if (kind == 'space') {
      final lobby = channels(
        selected!,
      ).where((c) => c['channel_kind'] == 'text').firstOrNull;
      if (lobby != null) await open(lobby['id'] as String);
    }
  }

  void _mergeEvents(List<Json> incoming, {bool older = false}) {
    _historyRevision++;
    if (matrixConnected) {
      final updates = {for (final e in incoming) e['event_id'] as String: e};
      final confirmed = updates.keys.toSet();
      final previous = _matrixEvents
          .where(
            (e) =>
                !_pendingEchoes.contains(e['event_id']) ||
                !confirmed.contains(e['event_id']),
          )
          .map((e) => updates[e['event_id']] ?? e)
          .toList();
      _pendingEchoes.removeAll(confirmed);
      final known = previous.map((e) => e['event_id']).toSet();
      final added = incoming.where((e) => !known.contains(e['event_id']));
      // The homeserver/SDK supplies DAG order. Remote timestamps are untrusted.
      _matrixEvents = older ? [...added, ...previous] : [...previous, ...added];
      events = renderMatrixTimeline(_matrixEvents, user?['user_id'] as String?);
      return;
    }
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
    requireNetwork();
    loadingOlder = true;
    notifyListeners();
    try {
      final wire = matrixRoom(room);
      final data = matrixConnected && wire != null
          ? await matrix.readNetwork(
              (transport) => transport.history(wire, cursor),
            )
          : await request(
              '/api/groups/$room/events?before=${Uri.encodeQueryComponent(cursor)}',
            );
      if (account == accountKey && room == selected) {
        _mergeEvents((data['events'] as List).cast<Json>(), older: true);
        nextCursor = data['next_cursor'] as String?;
        await _saveHistory(room);
      }
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  Future<void> markRead(String room, String event) async {
    if (readOnly) return;
    if (_read[room] == event) return;
    final account = accountKey;
    _read[room] = event;
    try {
      final wire = matrixRoom(room);
      if (matrixConnected && wire != null) {
        await matrix.transport.action({
          'action': 'read',
          'room': wire,
          'event': event,
        });
      } else {
        await request(
          '/api/groups/$room/read',
          method: 'POST',
          body: {'event_id': event},
        );
      }
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
    if (matrixConnected) await matrix.syncNow();
    await open(result['id'] as String);
  }

  String userId(String value) {
    final entered = value.trim();
    if (entered.startsWith('@') && entered.contains(':')) return entered;
    final v = entered.toLowerCase();
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
    requireNetwork();
    final account = accountKey;
    if (matrixConnected &&
        !friends.any((f) => f['user_id'] == userId(person))) {
      final result = await matrix.transport.action({
        'action': 'direct',
        'user': userId(person),
      });
      await matrix.refreshRooms();
      await refresh();
      if (account != accountKey) throw ApiException(409, 'session_changed');
      final room = groups
          .where((g) => g['room_id'] == result['room_id'])
          .firstOrNull;
      if (room != null) await open(room['id'] as String);
      return;
    }
    final result = await request(
      '/api/direct',
      method: 'POST',
      body: {'user_id': userId(person)},
    );
    await refresh();
    if (matrixConnected) {
      // The new local room must first arrive in the Matrix sync before use.
      await matrix.syncNow();
      final wire =
          result['room_id'] as String? ?? matrixRoom(result['id'] as String);
      if (wire == null) {
        throw StateError(
          'This conversation is still syncing. Try again in a moment.',
        );
      }
      await matrix.ensureJoinedRoom(wire);
      if (account != accountKey) throw ApiException(409, 'session_changed');
      final room = matrix.roomList
          .where((r) => r['room_id'] == wire)
          .firstOrNull;
      if (room?['encrypted'] is! bool || room?['can_encrypt'] is! bool) {
        throw StateError(
          'This conversation is still syncing. Try again in a moment.',
        );
      }
      // Existing DMs retain their encryption policy and ACL. Only participants
      // allowed by the SDK's synced power levels can enable encryption.
      if (room!['encrypted'] == false && room['can_encrypt'] == true) {
        await matrix.transport.action({'action': 'encrypt', 'room': wire});
        await matrix.refreshRooms();
      }
    }
    if (account != accountKey) throw ApiException(409, 'session_changed');
    await open(result['id'] as String);
  }

  Future<Json> subgroups(String id) => request('/api/groups/$id/subgroups');

  Future<void> conversation(
    String name,
    List<String> members, {
    String? contextId,
  }) async {
    if (members.length == 1 && contextId == null) {
      return messageFriend(members.single);
    }
    final key = 'conversation:$contextId:$name:${members.join(',')}';
    final result = await request(
      '/api/conversations',
      method: 'POST',
      body: {
        'name': name,
        'member_ids': members,
        if (contextId != null) 'context_id': contextId,
        'txn_id': _transactions.putIfAbsent(key, transactionId),
      },
    );
    _transactions.remove(key);
    if (matrixConnected) await matrix.syncNow();
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

  Future<Json> thread(String room, String event, {String? before}) async {
    final wire = matrixRoom(room);
    // Space entries and their authored edits are custom Matrix objects rendered
    // by the space content API, alongside ordinary thread replies.
    final managedSpace =
        group(room)?['kind'] == 'space' && group(room)?['matrix_only'] != true;
    if (matrixConnected && wire != null && !managedSpace) {
      Json? cached;
      try {
        cached = await matrix.readLocal('thread', room: wire, event: event);
      } catch (_) {}
      Json result;
      if (readOnly) {
        result =
            cached ??
            (throw StateError(
              'This thread is not saved on this device. Connect to load it.',
            ));
      } else {
        try {
          result = await matrix.readNetwork(
            (transport) => transport.thread(wire, event, before),
          );
          final page = (result['events'] as List).cast<Json>();
          final previous = ((cached?['events'] as List?) ?? []).cast<Json>();
          final updates = {for (final e in page) e['event_id']: e};
          final known = previous.map((e) => e['event_id']).toSet();
          final kept = [for (final e in previous) updates[e['event_id']] ?? e];
          final added = page.where((e) => !known.contains(e['event_id']));
          result = {
            ...result,
            'events': before == null
                ? [...kept, ...added]
                : [...added, ...kept],
          };
          await _saveLocal('thread', result, room: wire, event: event);
        } catch (e) {
          if (!matrixNetworkFailure(e) || cached == null) rethrow;
          notifyListeners();
          result = cached;
        }
      }
      final rendered = renderMatrixTimeline([
        result['root'] as Json,
        ...(result['events'] as List).cast<Json>(),
        ..._matrixEvents.where(
          (e) => e['type'] == 'm.reaction' || e['type'] == 'm.room.redaction',
        ),
      ], user?['user_id'] as String?);
      final byId = {for (final e in rendered) e['event_id']: e};
      return {
        ...result,
        'root': byId[(result['root'] as Json)['event_id']],
        'events': [
          for (final e in (result['events'] as List).cast<Json>())
            if (byId[e['event_id']] case final rendered?) rendered,
        ],
      };
    }
    return request(
      '/api/groups/$room/thread?event_id=${Uri.encodeQueryComponent(event)}${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}',
    );
  }

  Future<void> react(
    String room,
    String event,
    String emoji,
    bool active,
  ) async {
    requireNetwork();
    final key = 'reaction:$room:$event:$emoji:$active';
    final wire = matrixRoom(room);
    if (matrixConnected && wire != null) {
      await matrix.transport.action({
        'action': 'reaction',
        'room': wire,
        'event': event,
        'key': emoji,
        'active': active,
        'transaction': _transactions.putIfAbsent(key, transactionId),
      });
      _transactions.remove(key);
      await refresh();
      return;
    }
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
    requireSpace(room);
    final key = 'edit:$room:$event:$title:$body';
    await request(
      '/api/spaces/$room/entry',
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

  Future<void> updateGroup(
    String id, {
    String? name,
    String? description,
  }) async {
    requireNetwork();
    final wire = matrixRoom(id);
    if (matrixConnected && wire != null) {
      if (name != null) {
        await matrix.transport.action({
          'action': 'rename',
          'room': wire,
          'name': name,
        });
      }
      if (description != null) {
        await matrix.transport.action({
          'action': 'state',
          'room': wire,
          'type': 'm.room.topic',
          'content': {'topic': description},
        });
      }
      await matrix.refreshRooms();
    } else {
      await request(
        '/api/groups/$id',
        method: 'PATCH',
        body: {
          if (name != null) 'name': name,
          if (description != null) 'description': description,
        },
      );
    }
    await refresh();
  }

  Future<void> enableEncryption(String id) async {
    requireNetwork();
    final wire = matrixRoom(id);
    if (!matrixConnected || wire == null) {
      throw StateError('Connect Matrix messaging first.');
    }
    await matrix.transport.action({'action': 'encrypt', 'room': wire});
    await matrix.refreshRooms();
    await refresh();
  }

  Future<void> joinMatrixRoom(String target) async {
    requireNetwork();
    if (!matrixConnected) throw StateError('Connect Matrix messaging first.');
    final url = Uri.tryParse(target.trim());
    final String room;
    final List<String> via;
    if (url?.host == 'matrix.to') {
      final link = Uri.parse(url!.fragment);
      room = Uri.decodeComponent(link.path.replaceFirst(RegExp(r'^/'), ''));
      via = link.queryParametersAll['via'] ?? [];
    } else {
      room = target.trim();
      via = [];
    }
    if (!room.startsWith('!') && !room.startsWith('#')) {
      throw StateError('Enter a Matrix room ID, alias or matrix.to room link.');
    }
    final result = await matrix.transport.action({
      'action': 'join',
      'room': room,
      'via': via,
    });
    await matrix.refreshRooms();
    await refresh();
    final joined = groups
        .where((g) => g['room_id'] == result['room_id'])
        .firstOrNull;
    if (joined != null) await open(joined['id'] as String);
  }

  Future<void> membership(String id, String action, [String? person]) async {
    requireNetwork();
    final wire = matrixRoom(id);
    final accepting = action == 'accept' || action == 'join';
    // A delegated local invitation also grants River access to calls/publishing.
    // Keep that explicit approval path for local invitations.
    if (matrixConnected &&
        wire != null &&
        (!accepting || group(id)?['matrix_only'] == true)) {
      await matrix.transport.action({
        'action': switch (action) {
          'accept' => 'join',
          'remove' => 'kick',
          _ => action,
        },
        'room': wire,
        if (person != null) 'user': userId(person),
      });
      await matrix.refreshRooms();
      await refresh();
      return;
    }
    await request(
      '/api/groups/$id/membership',
      method: 'POST',
      body: {
        'action': accepting ? 'accept' : action,
        if (person != null) 'user_id': userId(person),
      },
    );
    if (matrixConnected) await matrix.syncNow();
    if (matrixConnected && accepting && wire != null) {
      await matrix.ensureJoinedRoom(wire);
    }
    await refresh();
  }

  Future<Json> send(
    String id,
    String type,
    Json content,
    String txn, {
    bool refreshAfter = true,
  }) => RiverPerformance.measure(
    'message.send',
    () => _sendMessage(id, type, content, txn, refreshAfter: refreshAfter),
  );

  Future<Json> _sendMessage(
    String id,
    String type,
    Json content,
    String txn, {
    bool refreshAfter = true,
  }) async {
    requireNetwork();
    final account = accountKey;
    final wire = matrixRoom(id);
    final delegatedContent = [
      'cool.gravitas.river.post.v1',
      'cool.gravitas.river.discussion.v1',
    ].contains(type);
    if (delegatedContent) {
      requireSpace(id);
      content = {...content, if (wire != null) 'space_id': wire};
    }
    if (delegatedContent && encrypted(id)) {
      throw StateError(
        'Public posts and discussions cannot be created in an encrypted room. Use encrypted chat instead.',
      );
    }
    if (!delegatedContent &&
        matrixEnabled &&
        (!matrixConnected || wire == null)) {
      throw StateError(
        'Connect Matrix messaging and wait for this room to sync before sending.',
      );
    }
    if (encrypted(id) && !matrixConnected) {
      throw StateError(
        'Reconnect Matrix messaging to send to this encrypted room.',
      );
    }
    if (encrypted(id) &&
        (content['cool.gravitas.river.attachments'] as List? ?? [])
            .isNotEmpty) {
      throw StateError(
        'Remove the pending legacy files and attach them again for encrypted delivery.',
      );
    }
    if (!delegatedContent && matrixConnected && wire != null) {
      await matrix.ensureJoinedRoom(wire);
    }
    if (account != accountKey) throw ApiException(409, 'session_changed');
    final result = !delegatedContent && matrixConnected && wire != null
        ? await matrix.transport.send(wire, type, content, txn)
        : await request(
            delegatedContent
                ? '/api/spaces/$id/entries/$type/$txn'
                : '/api/groups/$id/events/$type/$txn',
            method: 'PUT',
            body: {'content': content},
          );
    if (account != accountKey) throw ApiException(409, 'session_changed');
    if (refreshAfter) {
      if (!delegatedContent && selected == id && result['event_id'] is String) {
        _mergeEvents([
          {
            'event_id': result['event_id'],
            'room_id': wire ?? id,
            'sender': user?['user_id'],
            'type': type,
            'content': content,
            'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
            'river_encrypted': encrypted(id),
          },
        ]);
        if (matrixConnected) {
          _pendingEchoes.add(result['event_id'] as String);
          unawaited(_saveHistory(id));
        }
        notifyListeners();
      }
      if (delegatedContent) await refresh();
    }
    return result;
  }

  Future<void> sendMatrixFile(
    String id,
    String name,
    String mime,
    Uint8List bytes,
  ) async {
    requireNetwork();
    final wire = matrixRoom(id), account = accountKey;
    if (!matrixConnected || wire == null) {
      throw StateError('Connect Matrix messaging first.');
    }
    final key = 'file:$wire:$name:$mime:${sha256.convert(bytes)}';
    await matrix.transport.sendAttachment(
      wire,
      name,
      mime,
      bytes,
      _transactions.putIfAbsent(key, transactionId),
    );
    if (account != accountKey) throw ApiException(409, 'session_changed');
    _transactions.remove(key);
    if (selected == id) {
      // Delivery is already acknowledged. A history outage must not turn a
      // successful attachment into an apparent failure and invite duplicates.
      unawaited(
        _loadSelected().catchError((Object e) {
          if (account == accountKey && selected == id) {
            error = _backgroundError(e);
            notifyListeners();
          }
        }),
      );
    }
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

  Future<void> postReaction(
    String event,
    String emoji,
    bool active, {
    String? target,
  }) async {
    if (user == null) throw ApiException(401, 'login_required');
    final key = 'public-reaction:$event:$target:$emoji:$active';
    await request(
      '/api/posts/${Uri.encodeComponent(event)}/reactions',
      method: 'POST',
      body: {
        'key': emoji,
        'active': active,
        if (target != null) 'target_id': target,
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
    _apiConnection.dispose();
    timer?.cancel();
    _live?.close();
    _calls?.dispose();
    _matrix?.dispose();
    final oldFiles = files;
    if (oldFiles != null) {
      unawaited(oldFiles.close().then((_) => oldFiles.dispose()));
    }
    changes.close();
    client.close();
    super.dispose();
  }
}

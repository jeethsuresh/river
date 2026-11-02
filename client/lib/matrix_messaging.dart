import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:river_matrix/river_matrix.dart';
import 'package:url_launcher/url_launcher.dart';

import 'matrix_store_location.dart';
import 'performance.dart';
import 'connection_health.dart';

typedef MatrixJson = Map<String, dynamic>;
typedef MatrixRequest =
    Future<MatrixJson> Function(String path, {String method, MatrixJson? body});

String _randomSecret() => base64UrlEncode(
  List.generate(32, (_) => Random.secure().nextInt(256)),
).replaceAll('=', '');

abstract interface class MatrixTransport {
  Future<MatrixJson> login(String token);
  Future<String> credentials();
  Future<MatrixJson> sync();
  Future<MatrixJson> rooms();
  Future<MatrixJson> history(String room, String? cursor);
  Future<MatrixJson> thread(String room, String event, String? cursor);
  Future<MatrixJson> members(String room);
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  );
  Future<MatrixJson> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  );
  Future<Uint8List> downloadAttachment(MatrixJson content);
  Future<MatrixJson> action(MatrixJson payload);
  Future<MatrixJson> security();
  Future<MatrixJson> setupRecovery(MatrixJson? authentication);
  Future<MatrixJson> recover(String key);
  Future<MatrixJson> requestVerification(String device);
  Future<MatrixJson> verificationAction(String flow, String action);
  Future<MatrixJson> verificationQr(String flow);
  Future<MatrixJson> scanVerificationImage(String flow, Uint8List bytes);
  Future<void> close(bool logout);
}

typedef MatrixFactory =
    Future<MatrixTransport> Function(MatrixJson configuration);

// Any authenticated SDK request can refresh its session, including a request
// that subsequently fails. Complete the durable save before returning to UI.
class _DurableMatrixTransport implements MatrixTransport {
  _DurableMatrixTransport(this.inner, this.persist);
  final MatrixTransport inner;
  final Future<void> Function() persist;
  Future<T> _run<T>(String label, Future<T> Function() operation) =>
      RiverPerformance.measure(label, () async {
        try {
          return await operation();
        } finally {
          await persist();
        }
      });

  @override
  Future<String> credentials() => inner.credentials();
  @override
  Future<MatrixJson> login(String token) =>
      _run('matrix.login', () => inner.login(token));
  @override
  Future<MatrixJson> sync() => _run('matrix.sync', inner.sync);
  @override
  Future<MatrixJson> rooms() => _run('matrix.rooms', inner.rooms);
  @override
  Future<MatrixJson> history(String room, String? cursor) =>
      _run('matrix.history', () => inner.history(room, cursor));
  @override
  Future<MatrixJson> thread(String room, String event, String? cursor) =>
      _run('matrix.thread', () => inner.thread(room, event, cursor));
  @override
  Future<MatrixJson> members(String room) =>
      _run('matrix.members', () => inner.members(room));
  @override
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  ) => _run('matrix.send', () => inner.send(room, type, content, txn));
  @override
  Future<MatrixJson> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  ) => _run(
    'matrix.sendAttachment',
    () => inner.sendAttachment(room, name, mime, bytes, txn),
  );
  @override
  Future<Uint8List> downloadAttachment(MatrixJson content) => _run(
    'matrix.downloadAttachment',
    () => inner.downloadAttachment(content),
  );
  @override
  Future<MatrixJson> action(MatrixJson payload) =>
      _run('matrix.action', () => inner.action(payload));
  @override
  Future<MatrixJson> security() => _run('matrix.security', inner.security);
  @override
  Future<MatrixJson> setupRecovery(MatrixJson? authentication) =>
      _run('matrix.setupRecovery', () => inner.setupRecovery(authentication));
  @override
  Future<MatrixJson> recover(String key) =>
      _run('matrix.recover', () => inner.recover(key));
  @override
  Future<MatrixJson> requestVerification(String device) => _run(
    'matrix.requestVerification',
    () => inner.requestVerification(device),
  );
  @override
  Future<MatrixJson> verificationAction(String flow, String action) => _run(
    'matrix.verificationAction',
    () => inner.verificationAction(flow, action),
  );
  @override
  Future<MatrixJson> verificationQr(String flow) =>
      _run('matrix.verificationQr', () => inner.verificationQr(flow));
  @override
  Future<MatrixJson> scanVerificationImage(String flow, Uint8List bytes) =>
      _run(
        'matrix.scanVerificationImage',
        () => inner.scanVerificationImage(flow, bytes),
      );
  @override
  Future<void> close(bool logout) => inner.close(logout);
}

class RustMatrixTransport implements MatrixTransport {
  RustMatrixTransport(this.engine);
  final MatrixConnection engine;
  static Future<void>? _initialization;
  static Future<MatrixTransport> open(MatrixJson config) async {
    try {
      await (_initialization ??= RustLib.init());
    } catch (_) {
      _initialization = null;
      rethrow;
    }
    return RustMatrixTransport(
      await MatrixConnection.open(
        homeserver: config['homeserver'] as String,
        expectedUser: config['user_id'] as String,
        store: config['store'] as String,
        storeKey: config['store_key'] as String,
        session: config['session'] as String?,
      ),
    );
  }

  Future<MatrixJson> _json(Future<String> value) async =>
      (jsonDecode(await value) as Map).cast<String, dynamic>();
  @override
  Future<MatrixJson> login(String token) =>
      _json(engine.login(loginToken: token));
  @override
  Future<String> credentials() => engine.credentials();
  @override
  Future<MatrixJson> sync() => _json(engine.sync_());
  @override
  Future<MatrixJson> rooms() => _json(engine.rooms());
  @override
  Future<MatrixJson> history(String room, String? cursor) =>
      _json(engine.history(room: room, cursor: cursor));
  @override
  Future<MatrixJson> thread(String room, String event, String? cursor) =>
      _json(engine.thread(room: room, event: event, cursor: cursor));
  @override
  Future<MatrixJson> members(String room) => _json(engine.members(room: room));
  @override
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  ) => _json(
    engine.send(
      room: room,
      eventType: type,
      content: jsonEncode(content),
      transaction: txn,
    ),
  );
  @override
  Future<MatrixJson> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  ) => _json(
    engine.sendAttachment(
      room: room,
      name: name,
      contentType: mime,
      bytes: bytes,
      transaction: txn,
    ),
  );
  @override
  Future<Uint8List> downloadAttachment(MatrixJson content) =>
      engine.downloadAttachment(content: jsonEncode(content));
  @override
  Future<MatrixJson> action(MatrixJson payload) =>
      _json(engine.action(payload: jsonEncode(payload)));
  @override
  Future<MatrixJson> security() => _json(engine.security());
  @override
  Future<MatrixJson> setupRecovery(MatrixJson? authentication) => _json(
    engine.setupRecovery(
      authentication: authentication == null
          ? null
          : jsonEncode(authentication),
    ),
  );
  @override
  Future<MatrixJson> recover(String key) =>
      _json(engine.recover(recoveryKey: key));
  @override
  Future<MatrixJson> requestVerification(String device) =>
      _json(engine.requestVerification(device: device));
  @override
  Future<MatrixJson> verificationAction(String flow, String action) =>
      _json(engine.verificationAction(flow: flow, action: action));
  @override
  Future<MatrixJson> verificationQr(String flow) =>
      _json(engine.verificationQr(flow: flow));
  @override
  Future<MatrixJson> scanVerificationImage(String flow, Uint8List bytes) =>
      _json(engine.scanVerificationImage(flow: flow, bytes: bytes));
  @override
  Future<void> close(bool logout) async {
    try {
      await engine.close(logout: logout);
    } finally {
      engine.dispose();
    }
  }
}

abstract interface class MatrixStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureMatrixStorage implements MatrixStorage {
  const SecureMatrixStorage();
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Owns one authenticated River profile's local Matrix device. All delayed work
/// checks the profile generation before publishing results or saving a session.
class MatrixMessaging extends ChangeNotifier {
  MatrixMessaging({
    required this.request,
    required this.changed,
    MatrixFactory? factory,
    MatrixStorage? storage,
    Future<String> Function(String)? storeLocation,
    Future<void> Function(Uri)? launch,
    this.syncEnabled = true,
  }) : factory = factory ?? RustMatrixTransport.open,
       storage = storage ?? const SecureMatrixStorage(),
       storeLocation = storeLocation ?? matrixStoreLocation,
       launch =
           launch ??
           ((url) async {
             if (!await launchUrl(
               url,
               webOnlyWindowName: '_self',
               mode: kIsWeb
                   ? LaunchMode.platformDefault
                   : LaunchMode.externalApplication,
             )) {
               throw StateError('Unable to open Matrix sign-in');
             }
           });

  final MatrixRequest request;
  final VoidCallback changed;
  final MatrixFactory factory;
  final MatrixStorage storage;
  final Future<String> Function(String) storeLocation;
  final Future<void> Function(Uri) launch;
  final bool syncEnabled;
  MatrixTransport? _transport;
  MatrixJson? _profile, _configuration;
  Object? _credentialOwner;
  final _unsavedSessions = <String, MatrixJson>{};
  List<MatrixJson> roomList = [];
  String? error;
  bool connecting = false, _active = true, _disposed = false;
  late final _connection = ConnectionHealth(notifyListeners);
  bool get networkUnavailable => _connection.unavailable;
  bool get reconnecting => _connection.retrying;

  Future<T> readNetwork<T>(Future<T> Function(MatrixTransport) read) async {
    final generation = _generation, observation = _connection.begin();
    try {
      return await read(transport);
    } catch (e) {
      if (generation == _generation && matrixNetworkFailure(e)) {
        _connection.failed(observation);
      }
      rethrow;
    }
  }

  Future<void> _localQueue = Future.value();
  bool get connected => _transport != null;
  int _generation = 0, _revokeBefore = -1;
  bool _syncing = false;
  Future<MatrixJson>? _syncRequest;
  Future<void> _storageQueue = Future.value();

  String? get accountKey =>
      _profile == null ? null : '${_profile!['issuer']}|${_profile!['sub']}';
  String get _namespace => sha256.convert(utf8.encode(accountKey!)).toString();
  String get _sessionKey => 'river_matrix.session.$_namespace';
  String get _pendingKey => 'river_matrix.pending.$_namespace';
  String? get userId => _profile?['user_id'] as String?;

  void _guard(int generation) {
    if (_disposed || generation != _generation || _profile == null) {
      throw StateError('Matrix account changed');
    }
  }

  Future<T> _serializeStorage<T>(Future<T> Function() operation) {
    final result = _storageQueue.then((_) => operation());
    _storageQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> bind(MatrixJson profile, {bool synchronize = true}) async {
    final account = '${profile['issuer']}|${profile['sub']}';
    if (accountKey == account && (connected || connecting)) return;
    await disconnect();
    _profile = Map.of(profile);
    final generation = _generation;
    if (profile['user_id'] is! String || profile['issuer'] is! String) return;
    connecting = true;
    var finishingLink = false;
    final sessionKey = _sessionKey;
    try {
      // A failed secure-storage write must not discard a token already rotated
      // by the server. Retry that write before reopening the saved device.
      await _serializeStorage(() async {
        _guard(generation);
        final unsaved = _unsavedSessions[account];
        if (unsaved == null) return;
        await storage.write(sessionKey, jsonEncode(unsaved));
        _guard(generation);
        _unsavedSessions.remove(account);
      });
      final saved = await storage.read(sessionKey);
      _guard(generation);
      if (saved != null) {
        final config = (jsonDecode(saved) as Map).cast<String, dynamic>();
        if (config['user_id'] != userId ||
            config['homeserver'] != profile['issuer']) {
          throw StateError('Stored Matrix session belongs to another account');
        }
        final raw = await factory(config);
        if (generation != _generation || _disposed) {
          await raw.close(generation < _revokeBefore);
          return;
        }
        _configuration = config;
        final engine = _durable(raw, generation);
        try {
          final snapshot = await engine.rooms();
          _guard(generation);
          _transport = engine;
          roomList = (snapshot['rooms'] as List).cast<MatrixJson>();
          notifyListeners();
          changed();
          if (synchronize) _startSync();
        } catch (_) {
          if (generation == _generation) {
            _transport = null;
            _configuration = null;
            _credentialOwner = null;
          }
          await engine.close(generation < _revokeBefore);
          rethrow;
        }
      } else {
        final pending = await storage.read(_pendingKey);
        _guard(generation);
        if (pending != null) {
          final data = (jsonDecode(pending) as Map).cast<String, dynamic>();
          if (!kIsWeb || Uri.base.queryParameters['matrixLink'] == data['id']) {
            finishingLink = true;
            unawaited(_finishLink(data, generation));
          }
        }
      }
    } catch (_) {
      if (generation == _generation) {
        error =
            'Matrix messaging could not reconnect. Connect again to continue.';
        notifyListeners();
      }
    } finally {
      if (generation == _generation && !finishingLink) {
        connecting = false;
        notifyListeners();
      }
    }
  }

  Future<void> connect() async {
    if (_profile == null || connected || connecting) return;
    final generation = _generation;
    connecting = true;
    error = null;
    notifyListeners();
    try {
      final verifier = _randomSecret();
      final challenge = base64UrlEncode(
        sha256.convert(utf8.encode(verifier)).bytes,
      ).replaceAll('=', '');
      final link = await request(
        '/api/matrix/link',
        method: 'POST',
        body: {'challenge': challenge, 'platform': kIsWeb ? 'web' : 'native'},
      );
      _guard(generation);
      if (link['homeserver'] != _profile!['issuer'] ||
          link['user_id'] != userId) {
        throw StateError('Matrix sign-in belongs to another account');
      }
      final storeName = '$_namespace-${_randomSecret()}';
      final data = <String, dynamic>{
        ...link,
        'verifier': verifier,
        'store': await storeLocation(storeName),
        'store_key': _randomSecret(),
      };
      _guard(generation);
      final pendingKey = _pendingKey;
      await _serializeStorage(() async {
        _guard(generation);
        await storage.write(pendingKey, jsonEncode(data));
      });
      _guard(generation);
      await launch(Uri.parse(link['url'] as String));
      if (!kIsWeb) await _finishLink(data, generation);
    } catch (_) {
      if (generation == _generation) {
        error = 'Matrix sign-in failed. Please try again.';
      }
    } finally {
      if (generation == _generation) {
        connecting = false;
        notifyListeners();
      }
    }
  }

  Future<void> _finishLink(MatrixJson data, int generation) async {
    connecting = true;
    notifyListeners();
    MatrixTransport? engine;
    var persisted = false;
    try {
      for (var attempt = 0; attempt < 150; attempt++) {
        _guard(generation);
        if ((data['expires_at'] as int) * 1000 <=
            DateTime.now().millisecondsSinceEpoch) {
          throw StateError('Matrix sign-in expired');
        }
        final result = await request(
          '/api/matrix/poll',
          method: 'POST',
          body: {'id': data['id'], 'verifier': data['verifier']},
        );
        _guard(generation);
        if (result['pending'] == true) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        if (result['homeserver'] != _profile!['issuer'] ||
            result['user_id'] != userId) {
          throw StateError('Matrix sign-in belongs to another account');
        }
        final config = <String, dynamic>{
          'homeserver': result['homeserver'],
          'user_id': result['user_id'],
          'store': data['store'],
          'store_key': data['store_key'],
        };
        engine = await factory(config);
        _guard(generation);
        await engine.login(result['login_token'] as String);
        _guard(generation);
        config['session'] = await engine.credentials();
        _guard(generation);
        final sessionKey = _sessionKey, pendingKey = _pendingKey;
        final account = accountKey!;
        // Persist the encrypted store credentials before exposing this device.
        // Losing this write must not leave a seemingly connected, unrecoverable device.
        await _serializeStorage(() async {
          _guard(generation);
          await storage.write(sessionKey, jsonEncode(config));
          _unsavedSessions.remove(account);
        });
        persisted = true;
        _guard(generation);
        _configuration = config;
        engine = _durable(engine, generation);
        final snapshot = await engine.sync();
        _guard(generation);
        await _serializeStorage(() async {
          _guard(generation);
          await storage.delete(pendingKey);
        });
        _guard(generation);
        _transport = engine;
        engine = null;
        roomList = (snapshot['rooms'] as List).cast<MatrixJson>();
        changed();
        error = null;
        _startSync();
        return;
      }
      throw StateError('Matrix sign-in expired');
    } catch (_) {
      if (generation == _generation) {
        _configuration = null;
        _credentialOwner = null;
        error = 'Matrix sign-in did not finish. Please start again.';
      }
    } finally {
      if (engine != null) {
        try {
          await engine.close(!persisted || generation < _revokeBefore);
        } catch (_) {}
      }
      if (generation == _generation) {
        connecting = false;
        notifyListeners();
      }
    }
  }

  MatrixTransport _durable(MatrixTransport engine, int generation) {
    final owner = Object(), account = accountKey!, sessionKey = _sessionKey;
    _credentialOwner = owner;
    void guard() {
      _guard(generation);
      if (!identical(_credentialOwner, owner)) {
        throw StateError('Matrix device changed');
      }
    }

    return _DurableMatrixTransport(
      engine,
      () => _serializeStorage(() async {
        guard();
        // Read inside the same queue as the write: a delayed read must not
        // overwrite a newer rotation saved by a concurrent operation.
        final session = await engine.credentials();
        guard();
        final config = _configuration!;
        if (session == config['session']) return;
        final updated = {...config, 'session': session};
        _unsavedSessions[account] = updated;
        await storage.write(sessionKey, jsonEncode(updated));
        guard();
        _unsavedSessions.remove(account);
        // Advance the durable snapshot only after the write succeeds.
        _configuration = updated;
      }),
    );
  }

  Future<void> syncNow() async {
    await _syncOnce(_generation);
    changed();
  }

  Future<void> ensureJoinedRoom(String room) async {
    bool joined() =>
        roomList.any((r) => r['room_id'] == room && r['membership'] == 'join');
    // An already-running poll can finish just before the create/join mutation.
    // Allow the next poll to bring that room into the local SDK before using it.
    for (var attempt = 0; attempt < 2 && !joined(); attempt++) {
      await _syncOnce(_generation);
    }
    if (!joined()) {
      throw StateError(
        'This conversation is still syncing. Try again in a moment.',
      );
    }
  }

  Future<void> ensureWritableRoom(String room) async {
    await ensureJoinedRoom(room);
    if (roomList.any(
      (r) =>
          r['room_id'] == room &&
          (r['upgrade_pending'] == true || r['replacement_room'] is String),
    )) {
      throw StateError(
        'This conversation is moving to a compatible room. Try again in a moment.',
      );
    }
  }

  // Foreground mutations share the current long poll instead of queuing a
  // second full poll behind it. There is one credential write per result.
  Future<MatrixJson> _syncOnce(int generation) {
    final pending = _syncRequest;
    if (pending != null) return pending;
    final engine = transport;
    final observation = _connection.begin();
    late final Future<MatrixJson> operation;
    operation = (() async {
      try {
        final snapshot = await engine.sync();
        _guard(generation);
        _connection.succeeded(observation);
        roomList = (snapshot['rooms'] as List).cast<MatrixJson>();
        notifyListeners();
        return snapshot;
      } catch (e) {
        if (generation == _generation && matrixNetworkFailure(e)) {
          _connection.failed(observation);
        }
        rethrow;
      } finally {
        if (identical(_syncRequest, operation)) _syncRequest = null;
      }
    })();
    return _syncRequest = operation;
  }

  Future<MatrixJson?> readLocal(
    String scope, {
    String? room,
    String? event,
  }) async {
    // Capture the device before waiting: a delayed read must never cross an account change.
    final generation = _generation, engine = transport;
    await _localQueue;
    _guard(generation);
    final result = await engine.action({
      'action': 'local_read',
      'scope': scope,
      if (room != null) 'room': room,
      if (event != null) 'event': event,
    });
    _guard(generation);
    return (result['value'] as Map?)?.cast<String, dynamic>();
  }

  Future<void> writeLocal(
    String scope,
    MatrixJson? value, {
    String? room,
    String? event,
  }) {
    final generation = _generation, engine = transport;
    // Snapshot mutable UI objects before enqueuing the database write.
    final snapshot = jsonDecode(jsonEncode(value));
    final result = _localQueue.catchError((Object _) {}).then((_) async {
      _guard(generation);
      await engine.action({
        'action': 'local_write',
        'scope': scope,
        'value': snapshot,
        if (room != null) 'room': room,
        if (event != null) 'event': event,
      });
      _guard(generation);
    });
    _localQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> refreshRooms() async {
    final generation = _generation;
    final snapshot = await transport.rooms();
    _guard(generation);
    roomList = (snapshot['rooms'] as List).cast<MatrixJson>();
    notifyListeners();
    changed();
  }

  MatrixTransport get transport =>
      _transport ?? (throw StateError('Connect Matrix messaging first'));
  bool get active => _active;
  set active(bool value) {
    final transition = _active != value;
    if (transition) _connection.reset();
    _active = value;
    if (value) _startSync();
    if (transition) notifyListeners();
  }

  void _startSync() {
    if (!_active || !connected || _syncing || !syncEnabled || _disposed) return;
    _syncing = true;
    unawaited(_sync(_generation));
  }

  Future<void> _sync(int generation) async {
    var backoff = 1;
    try {
      while (!_disposed && _active && connected && generation == _generation) {
        try {
          final snapshot = await _syncOnce(generation);
          error = null;
          backoff = 1;
          notifyListeners();
          if (snapshot['credentials_changed'] == true ||
              (snapshot['changed'] as List? ?? []).isNotEmpty ||
              roomList.any((room) => room['encrypted'] == true)) {
            changed();
          }
        } catch (e) {
          if (generation != _generation || _disposed) break;
          if ('$e'.contains('RIVER_MATRIX_SESSION_EXPIRED')) {
            final old = _transport;
            _transport = null;
            _credentialOwner = null;
            _connection.reset();
            error =
                'This Matrix device session expired. Connect and verify this device again.';
            try {
              await old?.close(false);
            } catch (_) {}
            notifyListeners();
            break;
          }
          error = 'Matrix messaging is reconnecting…';
          notifyListeners();
          await Future<void>.delayed(Duration(seconds: backoff));
          backoff = min(backoff * 2, 60);
        }
      }
    } finally {
      _syncing = false;
      if (generation != _generation && connected) _startSync();
    }
  }

  Future<void> disconnect({bool logout = false}) async {
    _syncRequest = null;
    final sessionKey = _profile == null ? null : _sessionKey;
    final pendingKey = _profile == null ? null : _pendingKey;
    if (logout) _unsavedSessions.remove(accountKey);
    _generation++;
    if (logout) _revokeBefore = _generation;
    final old = _transport;
    _transport = null;
    _configuration = null;
    _credentialOwner = null;
    _profile = null;
    roomList = [];
    connecting = false;
    error = null;
    _connection.reset();
    try {
      if (logout) {
        await _serializeStorage(() async {
          try {
            if (sessionKey != null) await storage.delete(sessionKey);
          } finally {
            if (pendingKey != null) await storage.delete(pendingKey);
          }
        });
      }
    } finally {
      if (old != null) {
        try {
          await old.close(logout);
        } catch (_) {}
      }
      notifyListeners();
    }
  }

  Future<void> cancelConnect() async {
    if (_profile == null || connected) return;
    final pendingKey = _pendingKey;
    _generation++;
    connecting = false;
    error = null;
    await _serializeStorage(() => storage.delete(pendingKey));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connection.dispose();
    _unsavedSessions.clear();
    unawaited(disconnect());
    super.dispose();
  }
}

/// Only transport failures enable offline mode; authorization and disk failures
/// remain errors and must never be mistaken for an unavailable network.
bool matrixNetworkFailure(Object error) {
  final message = '$error';
  return message.contains('RIVER_NETWORK_UNAVAILABLE') ||
      message.contains('error sending request') ||
      message.contains('connection error') ||
      message.contains('operation timed out');
}

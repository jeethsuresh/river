// Runs only in the disposable integration container, with real browser time.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 3 || args.length > 4) {
    throw ArgumentError(
      'Expected browser, peer SPKI, test URL and optional smoke mode',
    );
  }
  final smoke = args.length == 4 && args[3] == 'smoke';
  final element = smoke ? 'matrix-smoke' : 'matrix-interop';
  final pass = smoke
      ? 'RIVER_MATRIX_BROWSER_PASS'
      : 'RIVER_MATRIX_WEB_CRYPTO_PASS';
  final fail = smoke
      ? 'RIVER_MATRIX_BROWSER_FAIL'
      : 'RIVER_MATRIX_WEB_CRYPTO_FAIL';
  final directory = await Directory.systemTemp.createTemp(
    'river-matrix-chrome-',
  );
  Process? browser;
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  var sequence = 0, navigations = 0, expectedNavigation = 0;
  final diagnostics = <String>[];
  try {
    browser = await Process.start(args[0], [
      '--headless',
      '--no-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--enable-unsafe-swiftshader',
      '--remote-debugging-address=127.0.0.1',
      '--remote-debugging-port=18793',
      '--user-data-dir=${directory.path}',
      if (args[1].isNotEmpty)
        '--ignore-certificate-errors-spki-list=${args[1]}',
      'about:blank',
    ]);
    unawaited(browser.stdout.drain<void>());
    browser.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.contains('DevTools listening')) return;
          diagnostics.add(line);
          if (diagnostics.length > 20) diagnostics.removeAt(0);
        });
    final http = HttpClient();
    String? debugger;
    for (var attempt = 0; attempt < 100; attempt++) {
      try {
        final response = await (await http.getUrl(
          Uri.parse('http://127.0.0.1:18793/json/list'),
        )).close();
        final pages =
            jsonDecode(await response.transform(utf8.decoder).join()) as List;
        debugger =
            (pages.firstWhere((p) => p['type'] == 'page')
                    as Map)['webSocketDebuggerUrl']
                as String?;
        if (debugger != null) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    http.close(force: true);
    if (debugger == null) {
      throw StateError('The local Chromium debugger did not start');
    }
    socket = await WebSocket.connect(debugger);
    subscription = socket.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      final id = message['id'];
      if (id is int) pending.remove(id)?.complete(message);
      if (message['method'] == 'Page.frameNavigated' &&
          (message['params']['frame'] as Map)['parentId'] == null) {
        navigations++;
      }
      if (message['method'] == 'Runtime.exceptionThrown') {
        final details = message['params']['exceptionDetails'];
        diagnostics.add(
          '${details['text']}: ${details['exception']?['description']}',
        );
      }
    });
    Future<Map<String, dynamic>> command(
      String method,
      Map<String, dynamic> params,
    ) {
      final id = ++sequence, result = Completer<Map<String, dynamic>>();
      pending[id] = result;
      socket!.add(jsonEncode({'id': id, 'method': method, 'params': params}));
      return result.future.timeout(const Duration(seconds: 20));
    }

    await command('Runtime.enable', {});
    await command('Page.enable', {});
    await command('Page.navigate', {'url': args[2]});
    var status = '';
    var reloadedOffline = false;
    final deadline = DateTime.now().add(const Duration(seconds: 150));
    while (DateTime.now().isBefore(deadline)) {
      final response = await command('Runtime.evaluate', {
        'expression': "document.getElementById('$element')?.textContent ?? ''",
        'returnByValue': true,
      });
      status = response['result']?['result']?['value'] as String? ?? '';
      if (status.contains(pass)) {
        if (smoke && reloadedOffline && navigations < expectedNavigation) {
          continue;
        }
        if (smoke && !reloadedOffline) {
          await command('Runtime.evaluate', {
            'expression': 'navigator.serviceWorker.ready.then(() => true)',
            'awaitPromise': true,
            'returnByValue': true,
          });
          await command('Network.enable', {});
          await command('Network.emulateNetworkConditions', {
            'offline': true,
            'latency': 0,
            'downloadThroughput': 0,
            'uploadThroughput': 0,
          });
          final denied = await command('Runtime.evaluate', {
            'expression':
                "fetch('/api/offline-smoke', {cache: 'no-store'}).then(() => false, () => true)",
            'awaitPromise': true,
            'returnByValue': true,
          });
          if (denied['result']?['result']?['value'] != true) {
            throw StateError(
              'The service worker cached an API response or the network stayed available',
            );
          }
          final server = int.tryParse(
            Platform.environment['MATRIX_OFFLINE_SERVER_PID'] ?? '',
          );
          if (server == null ||
              server <= 0 ||
              server == pid ||
              !Process.killPid(server)) {
            throw StateError(
              'The disposable web server could not be stopped for the offline reload',
            );
          }
          expectedNavigation = navigations + 1;
          await command('Page.reload', {'ignoreCache': false});
          reloadedOffline = true;
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        stdout.writeln(
          smoke
              ? 'RIVER MATRIX BROWSER encrypted IndexedDB and offline page reload PASS'
              : 'RIVER MATRIX WEB IndexedDB, production QR renderer/scanner, key transfer, history and encrypted attachment PASS',
        );
        return;
      }
      if (status.contains(fail)) {
        throw StateError(status);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('Browser test timed out: $status');
  } catch (e) {
    stderr.writeln(e);
    for (final line in diagnostics) {
      stderr.writeln(line);
    }
    exitCode = 1;
  } finally {
    if (browser != null) {
      try {
        // SIGTERM can leave Chromium's profile-writing child processes alive
        // after the launcher exits. Ask the browser to shut them down first.
        socket?.add(jsonEncode({'id': ++sequence, 'method': 'Browser.close'}));
        await browser.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        browser.kill();
        try {
          await browser.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          browser.kill(ProcessSignal.sigkill);
          await browser.exitCode;
        }
      }
    }
    await subscription?.cancel();
    await socket?.close();
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        // A final background write can briefly race recursive deletion on Linux.
        // Keep persistent cleanup errors visible instead of hiding test failures.
        if (error.osError?.errorCode != 39 || attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

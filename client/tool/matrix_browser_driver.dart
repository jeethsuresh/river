// Runs only in the disposable integration container, with real browser time.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('Expected browser, peer SPKI and test URL');
  }
  final directory = await Directory.systemTemp.createTemp(
    'river-matrix-chrome-',
  );
  Process? browser;
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  var sequence = 0;
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
    await command('Page.navigate', {'url': args[2]});
    var status = '';
    final deadline = DateTime.now().add(const Duration(seconds: 150));
    while (DateTime.now().isBefore(deadline)) {
      final response = await command('Runtime.evaluate', {
        'expression':
            "document.getElementById('matrix-interop')?.textContent ?? ''",
        'returnByValue': true,
      });
      status = response['result']?['result']?['value'] as String? ?? '';
      if (status.contains('RIVER_MATRIX_WEB_CRYPTO_PASS')) {
        stdout.writeln(
          'RIVER MATRIX WEB IndexedDB, production QR renderer/scanner, key transfer, history and encrypted attachment PASS',
        );
        return;
      }
      if (status.contains('RIVER_MATRIX_WEB_CRYPTO_FAIL')) {
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

// Build-time generation only. Account data is never part of the static manifest.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Expected Flutter web output directory');
  }
  final output = Directory(args.single).absolute;
  final files = await output
      .list(recursive: true, followLinks: false)
      .where((e) => e is File)
      .cast<File>()
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  final resources = <String, String>{};
  for (final file in files) {
    final key = file.path
        .substring(output.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    if (key == 'river_service_worker.js' ||
        key == 'flutter_service_worker.js' ||
        key.endsWith('.map')) {
      continue;
    }
    resources[key] = sha256.convert(await file.readAsBytes()).toString();
  }
  const core = [
    'index.html',
    'flutter_bootstrap.js',
    'main.dart.js',
    'flutter.js',
    'manifest.json',
    'icon.svg',
    'pkg/river_matrix_core.js',
    'pkg/river_matrix_core_bg.wasm',
  ];
  for (final key in core) {
    if (!resources.containsKey(key)) {
      throw StateError('Missing offline app resource: $key');
    }
  }
  final manifest = jsonEncode(resources);
  final version = sha256.convert(utf8.encode(manifest)).toString();
  final template = await File('tool/river_service_worker.js').readAsString();
  await File('${output.path}/river_service_worker.js').writeAsString(
    template
        .replaceAll('__RIVER_CACHE__', jsonEncode('river-shell-$version'))
        .replaceAll('__RIVER_RESOURCES__', manifest)
        .replaceAll('__RIVER_CORE__', jsonEncode(core)),
  );
  stdout.writeln(
    'Generated versioned River offline app shell (${resources.length} static resources)',
  );
}

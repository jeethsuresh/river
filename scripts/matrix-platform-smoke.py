#!/usr/bin/env python3
"""Create a disposable Flutter app that links the same SDK on every platform."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

platform = sys.argv[1]
if platform not in {'linux', 'windows', 'macos', 'ios'}:
    raise SystemExit('Expected a Flutter desktop or iOS target')
repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='river-matrix-platform-') as directory:
    app = Path(directory) / 'app'
    subprocess.run(['flutter', 'create', '--project-name', 'river_matrix_smoke',
                    '--platforms', platform, str(app)], check=True)
    manifest = app / 'pubspec.yaml'
    text = manifest.read_text()
    sdk = (repo / 'client/packages/river_matrix').as_posix()
    text = text.replace('dependencies:\n', f'dependencies:\n  river_matrix:\n    path: "{sdk}"\n', 1)
    manifest.write_text(text)
    (app / 'lib/main.dart').write_text('''import 'package:flutter/material.dart';
import 'package:river_matrix/river_matrix.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MaterialApp(home: Text('River Matrix platform build')));
}
''')
    subprocess.run(['flutter', 'pub', 'get'], cwd=app, check=True)
    command = ['flutter', 'build', platform, '--release']
    if platform == 'ios':
        command += ['--no-codesign']
    subprocess.run(command, cwd=app, check=True)

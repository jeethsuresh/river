import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:river/main.dart';
import 'package:river/api.dart';
import 'package:river_matrix/river_matrix.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native bundle loads plugins, credentials, storage and the real UI',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final file = File('${support.path}/desktop-smoke.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('durable desktop data', flush: true);
      expect(await file.readAsString(), 'durable desktop data');
      await file.delete();
      const secrets = FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );
      await secrets.write(
        key: 'desktop-smoke-only',
        value: 'encrypted desktop credential',
      );
      expect(
        await secrets.read(key: 'desktop-smoke-only'),
        'encrypted desktop credential',
      );
      await secrets.delete(key: 'desktop-smoke-only');
      await RustLib.init();
      final api = RiverApi(matrixEnabled: false)..loading = false;
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}

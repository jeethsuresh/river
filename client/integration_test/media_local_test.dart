import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test/media_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  mediaScenarios(
    (name, run, {required skip, required timeout}) => testWidgets(
      name,
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('River isolated media verification')),
            ),
          ),
        );
        await tester.runAsync(run);
      },
      skip: skip,
      timeout: timeout,
    ),
    native: true,
  );
}

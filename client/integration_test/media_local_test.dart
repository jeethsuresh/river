import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../test/media_scenarios.dart';
import 'package:river/call_widgets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  WidgetTester? currentTester;
  mediaScenarios(
    (name, run, {required skip, required timeout}) => testWidgets(
      name,
      (tester) async {
        currentTester = tester;
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('River isolated media verification')),
            ),
          ),
        );
        await tester.runAsync(run);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
      skip: skip,
      timeout: timeout,
    ),
    native: true,
    display: (api) async {
      await currentTester!.pumpWidget(
        MaterialApp(home: RiverCallScreen(api: api)),
      );
      await currentTester!.pump();
    },
  );
}

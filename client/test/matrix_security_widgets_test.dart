import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/matrix_messaging.dart';
import 'package:river/matrix_security_widgets.dart';
import 'matrix_messaging_test.dart'
    show MemoryMatrixStorage, FakeMatrixTransport, matrixHarness, matrixProfile;

class SecurityTransport extends FakeMatrixTransport {
  final actions = <String>[];
  MatrixJson flow = {
    'id': 'flow',
    'ready': true,
    'done': false,
    'started_here': true,
  };
  @override
  Future<MatrixJson> security() async => {
    'devices': [],
    'requests': [flow],
    'device_id': 'THIS',
    'has_identity': true,
  };
  @override
  Future<MatrixJson> verificationQr(String flow) async => {
    'size': 21,
    'pixels': List.generate(21 * 21, (i) => i.isEven),
  };
  @override
  Future<MatrixJson> verificationAction(String flow, String action) async {
    actions.add(action);
    return {};
  }
}

void main() {
  testWidgets(
    'QR trust requires a scan and an explicit confirmation on the displaying device',
    (tester) async {
      final engine = SecurityTransport(), storage = MemoryMatrixStorage();
      final messaging = matrixHarness(storage, engine);
      await messaging.bind(matrixProfile);
      await messaging.connect();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MatrixSecurityPanel(messaging: messaging),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Yes, trust this device'), findsNothing);
      await tester.tap(find.text('Show QR code'));
      await tester.pumpAndSettle();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(engine.actions, isEmpty);
      engine.flow = {...engine.flow, 'method': 'qr', 'scanned': true};
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Yes, trust this device'));
      await tester.tap(find.text('Yes, trust this device'));
      await tester.pumpAndSettle();
      expect(engine.actions, ['confirm_qr']);
      engine.flow = {...engine.flow, 'done': true};
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Yes, trust this device'), findsNothing);
      expect(
        find.text(
          'Scan this code with your other device. Keep this screen open.',
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      messaging.dispose();
    },
  );
}

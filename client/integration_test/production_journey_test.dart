import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'production_journey_scenarios.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Headless browser frames run independently of tester.pump. Keep real
    // rendering active without waiting for an additional forced frame.
    binding.framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  }
  productionJourneyScenarios();
}
